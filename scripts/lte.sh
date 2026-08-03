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
  pkill -f open_xdatachannel.py 2>/dev/null || true
  sleep 1
  ip link set wwan0 down 2>/dev/null || true
  # FLR resets modem firmware so driver remove() doesn't block on unresponsive firmware
  if [ -e /sys/bus/pci/devices/0000:71:00.0/reset ]; then
    echo 1 > /sys/bus/pci/devices/0000:71:00.0/reset 2>/dev/null || true
    sleep 1
  fi
  /sbin/rmmod xmm7360 2>/dev/null || true
  sleep 1
  if [ -e /sys/bus/pci/devices/0000:71:00.0 ]; then
    echo 1 > /sys/bus/pci/devices/0000:71:00.0/remove
    sleep 1
  fi
  # Rescan only RP02 (modem's root port) — global rescan can kill the session
  echo 1 > /sys/bus/pci/devices/0000:00:1c.0/rescan
  for i in $(seq 1 10); do
    [ -e /sys/bus/pci/devices/0000:71:00.0 ] && break
    sleep 1
  done
  [ -e /sys/bus/pci/devices/0000:71:00.0 ] || { echo "ERROR: PCI device did not reappear"; return 1; }
  # udev may auto-bind the in-tree iosm driver on rescan before we get here
  /sbin/rmmod iosm 2>/dev/null || true
  /sbin/modprobe xmm7360 || { echo "ERROR: modprobe failed"; return 1; }
  for i in $(seq 1 10); do
    [ -e /dev/xmm0/rpc ] && break
    echo "  waiting for wwan interfaces... ($i)"
    sleep 1
  done
  [ -e /dev/xmm0/rpc ] || { echo "ERROR: wwan interfaces did not appear"; return 1; }
  echo "hard-reset done, wwan interfaces ready"
}

if [[ "$1" = "hard-reset" ]]; then
  hard_reset || exit 1
  exit 0
fi

bring_up() {
  echo "bringing wwan0 up!"

  if ! ip link show wwan0 &>/dev/null; then
    echo "wwan0 not found, loading module..."
    /sbin/rmmod iosm 2>/dev/null || true
    /sbin/modprobe xmm7360 || { echo "Failed to load xmm7360 module"; return 1; }
    sleep 1
  fi

  # Explicit bind in case udev didn't auto-bind after modprobe
  if [ ! -e /sys/bus/pci/devices/0000:71:00.0/driver ]; then
    echo 0000:71:00.0 > /sys/bus/pci/drivers/xmm7360/bind 2>/dev/null || true
    sleep 2
  fi
  for i in $(seq 1 15); do
    [ -e /dev/xmm0/rpc ] && break
    echo "  waiting for XMM RPC interface... ($i)"
    sleep 1
  done
  [ -e /dev/xmm0/rpc ] || { echo "ERROR: XMM RPC interface never appeared"; return 1; }
  python3 $SCRIPT_DIR/../rpc/open_xdatachannel.py -d || { echo "open_xdatachannel.py failed"; return 1; }
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
  sleep 1
  if ! timeout 10 ping -c 2 -W 5 -I wwan0 1.1.1.1 &>/dev/null; then
    echo "ERROR: wwan0 up but no connectivity"
    return 1
  fi
}

if [[ "$1" = "up" ]]; then
  if ! bring_up; then
    # open_xdatachannel.py fails outright (e.g. "Device or resource busy" on
    # /dev/xmm0/rpc) when the driver's RPC channel is left in a stuck state
    # from a prior crash/kill — a plain retry never clears it, only a PCIe
    # FLR + module reload does. Self-heal once before giving up.
    echo "up failed, self-healing: hard-resetting modem and retrying once..."
    if hard_reset && bring_up; then
      echo "self-heal succeeded"
    else
      echo "ERROR: up failed even after hard-reset, giving up"
      exit 1
    fi
  fi
fi
