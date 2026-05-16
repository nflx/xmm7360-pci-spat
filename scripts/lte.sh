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

# Auto-detect XMM7360 PCI device address and its parent root port.
# Used by flr, hard-reset, and up commands.
XMM_PCI=$(lspci -D 2>/dev/null | awk '/8086:7360/{print $1; exit}')
if [ -n "$XMM_PCI" ] && [ -e "/sys/bus/pci/devices/$XMM_PCI" ]; then
  XMM_RP=$(readlink /sys/bus/pci/devices/$XMM_PCI 2>/dev/null \
    | sed 's|.*/\([^/]*\)/[^/]*$|\1|')
fi

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
  # Unload conflicting modules before loading xmm7360
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
if [[ "$1" = "down" ]]; then
  echo "taking wwan0 down!"
  # Kill open_xdatachannel.py first — it holds runtime_usage=2 on the PCI
  # device, causing rmmod to block indefinitely if it's still running.
  pkill -f open_xdatachannel.py 2>/dev/null || true
  sleep 1
  # Capture IP before bringing the interface down
  WWAN_IP=$(ip -4 addr show wwan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  ip link set wwan0 down 2>/dev/null || true
  nmcli connection delete fake-wwan 2>/dev/null || true
  # RST open TCP connections that were using wwan0 so the browser fails over
  # to WiFi immediately instead of hanging until TCP timeout.
  if [[ -n "$WWAN_IP" ]]; then
    ss -K src "$WWAN_IP" 2>/dev/null || true
  fi
  exit
fi

# PCIe Function Level Reset — resets modem firmware without unloading module.
# Use when modem is unresponsive but the driver is still bound.
if [[ "$1" = "flr" ]]; then
  if [ -z "$XMM_PCI" ]; then
    echo "ERROR: XMM7360 PCI device not found (is the module loaded?)"
    exit 1
  fi
  echo "triggering PCIe Function Level Reset on XMM7360 ($XMM_PCI)..."
  echo 1 > /sys/bus/pci/devices/$XMM_PCI/reset
  echo "FLR done"
  exit 0
fi

# Full recovery: FLR + rmmod + PCI remove + root-port rescan + modprobe + bind.
# Use when lte up fails with "XMM RPC interface does not exist".
if [[ "$1" = "hard-reset" ]]; then
  if [ -z "$XMM_PCI" ] || [ -z "$XMM_RP" ]; then
    echo "ERROR: could not detect XMM7360 PCI device or its root port"
    exit 1
  fi
  echo "performing full PCIe + module reset ($XMM_PCI via $XMM_RP)..."
  pkill -f open_xdatachannel.py 2>/dev/null || true
  sleep 1
  ip link set wwan0 down 2>/dev/null || true
  # FLR resets modem firmware so driver remove() doesn't block on unresponsive firmware
  if [ -e /sys/bus/pci/devices/$XMM_PCI/reset ]; then
    echo 1 > /sys/bus/pci/devices/$XMM_PCI/reset 2>/dev/null || true
    sleep 1
  fi
  /sbin/rmmod xmm7360 2>/dev/null || true
  sleep 1
  if [ -e /sys/bus/pci/devices/$XMM_PCI ]; then
    echo 1 > /sys/bus/pci/devices/$XMM_PCI/remove
    sleep 1
  fi
  # Rescan only the modem's root port — global rescan can briefly take down
  # NVMe/USB PCIe devices and kill the running session.
  echo 1 > /sys/bus/pci/devices/$XMM_RP/rescan
  for i in $(seq 1 10); do
    [ -e /sys/bus/pci/devices/$XMM_PCI ] && break
    sleep 1
  done
  [ -e /sys/bus/pci/devices/$XMM_PCI ] || { echo "ERROR: PCI device did not reappear"; exit 1; }
  /sbin/modprobe xmm7360 || { echo "ERROR: modprobe failed"; exit 1; }
  for i in $(seq 1 10); do
    [ -e /dev/wwan0xmmrpc0 ] && break
    echo "  waiting for wwan interfaces... ($i)"
    sleep 1
  done
  [ -e /dev/wwan0xmmrpc0 ] || { echo "ERROR: wwan interfaces did not appear"; exit 1; }
  echo "hard-reset done, wwan interfaces ready"
fi

if [[ "$1" = "up" ]]; then
  echo "bringing wwan0 up!"

  if ! ip link show wwan0 &>/dev/null; then
    echo "wwan0 not found, loading module..."
    /sbin/rmmod iosm 2>/dev/null || true
    /sbin/modprobe xmm7360 || { echo "Failed to load xmm7360 module"; exit 1; }
    sleep 1
  fi

  # Explicit bind in case udev didn't auto-bind after modprobe (common after resume)
  if [ -n "$XMM_PCI" ] && [ ! -e /sys/bus/pci/devices/$XMM_PCI/driver ]; then
    echo $XMM_PCI > /sys/bus/pci/drivers/xmm7360/bind 2>/dev/null || true
    sleep 2
  fi
  # Wait up to 15s for the RPC interface (driver probe does DMA ring setup)
  for i in $(seq 1 15); do
    [ -e /dev/wwan0xmmrpc0 ] && break
    echo "  waiting for XMM RPC interface... ($i)"
    sleep 1
  done
  python3 $SCRIPT_DIR/../rpc/open_xdatachannel.py -d || { echo "open_xdatachannel.py failed, aborting"; exit 1; }
  ip link set wwan0 up
  nmcli connection delete fake-wwan 2>/dev/null || true
  nmcli connection add type dummy ifname dummy0 con-name fake-wwan
  nmcli connection up fake-wwan
fi
