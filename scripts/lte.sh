#!/bin/bash
# install: sudo ./scripts/lte.sh setup
# use: sudo lte up

if [[ "$1" = "" ]]; then
  echo "nothing to do, try with up, down, setup or remove"
  exit 1
fi

SCRIPT_PATH=$(readlink -f $0)
SCRIPT_DIR=`dirname $SCRIPT_PATH`
CONF_FILE=$SCRIPT_DIR/../xmm7360.ini

# check if xmm7360.ini is available or exit
if [ -f "$CONF_FILE" ]; then
  source $CONF_FILE
else
  echo "no configuration file found, you can create it by copying the sample file like this:"
  echo "cp $CONF_FILE.sample $CONF_FILE"
  exit 1
fi

# run as root (Ubuntu GUI Tested)
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root, elevating!" 
  exec pkexec $SCRIPT_DIR/lte.sh $1
  exit 0
fi

# switch to correct directory
cd $SCRIPT_DIR/..

echo "lte.sh: manage xmm7360-pci"
echo "APN: $apn"
echo "Script: $SCRIPT_DIR/lte.sh; Link: $BIN_DIR"
echo ""

# Shared, file-based status so lte-indicator can show what's actually
# happening (waiting for RPC? hard-resetting? which minute of a slow
# post-resume re-attach?) instead of one generic "connecting" for the
# whole duration a caller holds the lock below — regardless of whether
# that caller is this terminal, the sleep hook, or the indicator itself.
# World-readable since lte.sh runs as root but the indicator reads this
# as the desktop user. Re-written (not just left alone) on every poll of
# a long-running wait, so its mtime tracks whether we're still making
# progress or have gone silently stuck.
PHASE_FILE=/run/xmm7360-lte-phase
set_phase() {
  echo "$1" > "$PHASE_FILE" 2>/dev/null
  chmod 644 "$PHASE_FILE" 2>/dev/null || true
}

# install deps, module, and lte script to PATH
if [[ "$1" = "setup" ]]; then
  pip3 install pyroute2 configargparse --user

  unlink /usr/local/bin/lte || true
  ln -s $SCRIPT_DIR/lte.sh /usr/local/bin/lte
  chmod 755 /usr/local/bin/lte

  make
  /sbin/rmmod iosm 2>/dev/null || true
  /sbin/rmmod xmm7360 2>/dev/null || true
  /sbin/modprobe xmm7360 || echo "Warning: could not load module (may need reboot or DKMS update)"
fi

# remove interface, mod
if [[ "$1" = "remove" ]]; then
  ip link set wwan0 down
  rmmod xmm7360 || true
  unlink /usr/local/bin/lte || true
fi

# down param
#
# Deliberately NOT gated by the flock below: `down` (via its
# `pkill -f open_xdatachannel.py`) is the only way to interrupt an `up` that's
# stuck waiting on a slow post-resume cellular re-attach (which can genuinely
# take minutes, not seconds — the modem keeps streaming RPC traffic the whole
# time). Making `down` wait for that same lock would remove the user's only
# way to cancel a stuck attempt. The pkill causes the in-flight `up`'s
# bring_up to fail, which triggers its own hard-reset-and-retry self-heal —
# a real recovery path, not just a side effect to route around.
if [[ "$1" = "down" ]]; then
  echo "taking wwan0 down!"
  set_phase "Disconnecting..."
  # Kill open_xdatachannel.py so rmmod can succeed
  pkill -f open_xdatachannel.py 2>/dev/null || true
  sleep 1
  # Capture IP before bringing the interface down
  WWAN_IP=$(ip -4 addr show wwan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  ip link set wwan0 down 2>/dev/null || true
  nmcli connection delete fake-wwan 2>/dev/null || true
  # RST any open TCP connections that were using the wwan0 IP so the browser
  # fails over to WiFi immediately instead of hanging until TCP timeout
  if [[ -n "$WWAN_IP" ]]; then
    ss -K src "$WWAN_IP" 2>/dev/null || true
  fi
  set_phase "Disconnected"
  exit
fi

# Serialize state-mutating operations from here on. Without this, the systemd
# sleep hook's backgrounded post-resume "lte up" and lte-indicator's own D-Bus
# wake-triggered "sudo lte up" (fired independently, ~8s later) can run
# concurrently and step on each other's rmmod/modprobe/PCI remove-rescan
# sequence. A second invocation now waits for the first to finish instead of
# racing it. The wait is long (10 min) because a slow post-resume cellular
# re-attach inside a still-running `up` is normal, not stuck — `down` above
# is the way to actually cancel that, not a lock timeout.
exec 9>/run/lock/xmm7360-lte.lock
if ! flock -w 600 9; then
  echo "ERROR: another lte.sh operation is still running after 10 minutes, giving up"
  exit 1
fi

if [[ "$1" = "flr" ]]; then
  echo "triggering PCIe Function Level Reset on XMM7360..."
  echo 1 > /sys/bus/pci/devices/0000:71:00.0/reset
  echo "FLR done"
  exit 0
fi

hard_reset() {
  echo "performing full PCIe + module reset..."
  set_phase "Hard-resetting: stopping data channel"
  pkill -f open_xdatachannel.py 2>/dev/null || true
  sleep 1
  ip link set wwan0 down 2>/dev/null || true
  # FLR resets modem firmware so driver remove() doesn't block on unresponsive firmware
  set_phase "Hard-resetting: resetting modem firmware (FLR)"
  if [ -e /sys/bus/pci/devices/0000:71:00.0/reset ]; then
    echo 1 > /sys/bus/pci/devices/0000:71:00.0/reset 2>/dev/null || true
    sleep 1
  fi
  set_phase "Hard-resetting: unloading driver"
  /sbin/rmmod xmm7360 2>/dev/null || true
  sleep 1
  if [ -e /sys/bus/pci/devices/0000:71:00.0 ]; then
    echo 1 > /sys/bus/pci/devices/0000:71:00.0/remove
    sleep 1
  fi
  # Rescan only RP02 (modem's root port) — global rescan can kill the session
  set_phase "Hard-resetting: rescanning PCIe bus"
  echo 1 > /sys/bus/pci/devices/0000:00:1c.0/rescan
  for i in $(seq 1 10); do
    [ -e /sys/bus/pci/devices/0000:71:00.0 ] && break
    set_phase "Hard-resetting: waiting for modem to reappear on PCIe ($i/10s)"
    sleep 1
  done
  [ -e /sys/bus/pci/devices/0000:71:00.0 ] || { set_phase "Failed: hard-reset - PCI device did not reappear"; echo "ERROR: PCI device did not reappear"; return 1; }
  # udev may auto-bind the in-tree iosm driver on rescan before we get here
  /sbin/rmmod iosm 2>/dev/null || true
  set_phase "Hard-resetting: loading driver"
  /sbin/modprobe xmm7360 || { set_phase "Failed: hard-reset - modprobe failed"; echo "ERROR: modprobe failed"; return 1; }
  for i in $(seq 1 10); do
    [ -e /dev/xmm0/rpc ] && break
    echo "  waiting for wwan interfaces... ($i)"
    set_phase "Hard-resetting: waiting for RPC interface ($i/10s)"
    sleep 1
  done
  [ -e /dev/xmm0/rpc ] || { set_phase "Failed: hard-reset - wwan interfaces did not appear"; echo "ERROR: wwan interfaces did not appear"; return 1; }
  echo "hard-reset done, wwan interfaces ready"
  set_phase "Hard-reset complete"
}

if [[ "$1" = "hard-reset" ]]; then
  hard_reset || exit 1
  exit 0
fi

bring_up() {
  echo "bringing wwan0 up!"

  if ! ip link show wwan0 &>/dev/null; then
    echo "wwan0 not found, loading module..."
    set_phase "Loading modem driver"
    /sbin/rmmod iosm 2>/dev/null || true
    /sbin/modprobe xmm7360 || { set_phase "Failed: could not load xmm7360 module"; echo "Failed to load xmm7360 module"; return 1; }
    sleep 1
  fi

  # Explicit bind in case udev didn't auto-bind after modprobe.
  # Grouped so 2>/dev/null actually suppresses bash's own "cannot open
  # bind for writing" message — a bare `cmd > file 2>/dev/null` fails to
  # redirect that particular error, since it's raised while opening the
  # first redirect target, before the second redirect is set up.
  if [ ! -e /sys/bus/pci/devices/0000:71:00.0/driver ]; then
    set_phase "Binding driver to modem"
    { echo 0000:71:00.0 > /sys/bus/pci/drivers/xmm7360/bind; } 2>/dev/null || true
    sleep 2
  fi
  for i in $(seq 1 15); do
    [ -e /dev/xmm0/rpc ] && break
    echo "  waiting for XMM RPC interface... ($i)"
    set_phase "Waiting for modem RPC interface ($i/15s)"
    sleep 1
  done
  [ -e /dev/xmm0/rpc ] || { set_phase "Failed: XMM RPC interface never appeared"; echo "ERROR: XMM RPC interface never appeared"; return 1; }

  # open_xdatachannel.py normally takes 15-30s but can legitimately run for
  # minutes during a post-resume cellular re-attach (confirmed live
  # 2026-08-03: 3.5 min of continuous RPC traffic before success). Run it in
  # the background and poll instead of a plain blocking call, so (a) the
  # phase file gets a live elapsed-time update every 5s — proof it's still
  # working, not just a static message sitting there for minutes — and
  # (b) an actual hang (not just slow) past 5 min gets killed and detected
  # instead of blocking `up` — and this whole script's flock — forever.
  set_phase "Opening data channel (RPC handshake)..."
  python3 "$SCRIPT_DIR/../rpc/open_xdatachannel.py" -d &
  local dc_pid=$!
  local elapsed=0
  while kill -0 "$dc_pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "$elapsed" -ge 300 ]; then
      kill "$dc_pid" 2>/dev/null
      wait "$dc_pid" 2>/dev/null
      set_phase "Failed: data channel hung (no response after 5 min)"
      echo "open_xdatachannel.py failed or hung (timed out after 5 min)"
      return 1
    fi
    set_phase "Opening data channel (RPC handshake, ${elapsed}s so far)..."
  done
  wait "$dc_pid"
  if [ $? -ne 0 ]; then
    set_phase "Failed: data channel setup failed"
    echo "open_xdatachannel.py failed"
    return 1
  fi

  ip link set wwan0 up
  nmcli connection delete fake-wwan 2>/dev/null || true
  nmcli connection add type dummy ifname dummy0 con-name fake-wwan
  nmcli connection up fake-wwan

  # open_xdatachannel.py exiting 0 and nmcli reporting "up" only means the
  # RPC calls and route/link setup succeeded — after a bad suspend/resume
  # cycle the modem can still ack all of that while its data path is dead,
  # leaving a connection that looks fine but passes no traffic. Treat that
  # as a bring-up failure too, so the caller's hard-reset retry actually
  # fires instead of leaving a zombie link that only a manual
  # disconnect/reconnect cycle would eventually clear.
  #
  # But a single quick ping here was firing that failure — and the caller's
  # hard-reset self-heal — *during* a legitimate slow re-attach that would
  # have succeeded on its own (same 3.5-minute quirk as above), restarting
  # the clock and making the "hang" worse, not better. Poll patiently
  # instead of failing fast; only report failure once even this patient
  # window is exhausted. Phase file refreshed every iteration so a genuine
  # stall (mtime going stale) is distinguishable from normal slow progress.
  echo "waiting for connectivity (a post-resume re-attach can take minutes)..."
  for i in $(seq 1 24); do
    set_phase "Waiting for connectivity (post-resume re-attach can take minutes, ${i}/24 x5s)"
    if timeout 5 ping -c 1 -W 4 -I wwan0 1.1.1.1 &>/dev/null; then
      echo "connectivity confirmed"
      set_phase "Connected"
      return 0
    fi
    sleep 5
  done
  set_phase "Failed: wwan0 up but no connectivity after 4 minutes"
  echo "ERROR: wwan0 up but no connectivity after 4 minutes"
  return 1
}

if [[ "$1" = "up" ]]; then
  set_phase "Connecting..."
  if ! bring_up; then
    # open_xdatachannel.py fails outright (e.g. "Device or resource busy" on
    # /dev/xmm0/rpc) when the driver's RPC channel is left in a stuck state
    # from a prior crash/kill — a plain retry never clears it, only a PCIe
    # FLR + module reload does. Self-heal once before giving up.
    echo "up failed, self-healing: hard-resetting modem and retrying once..."
    set_phase "First attempt failed - self-healing with a hard-reset"
    if hard_reset && bring_up; then
      echo "self-heal succeeded"
    else
      set_phase "Failed: up failed even after hard-reset, giving up"
      echo "ERROR: up failed even after hard-reset, giving up"
      exit 1
    fi
  fi
fi
