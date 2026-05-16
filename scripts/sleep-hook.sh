#!/bin/bash
# Systemd sleep hook for xmm7360 LTE modem.
# Unloads the driver before suspend so the PCIe device goes quiet
# (no PME wakeup events). Reloads and reconnects after resume.
#
# Install: sudo cp /full/path/to/sleep-hook.sh /usr/lib/systemd/system-sleep/xmm7360-sleep.sh
#          sudo chmod +x /usr/lib/systemd/system-sleep/xmm7360-sleep.sh
#
# Also required for suspend to work (Dell XPS + XMM7360):
#   1. Mask ACPI GPE 0x6E storm from modem:
#      sudo systemctl enable --now acpi-mask-gpe6e.service
#      (see sleep-hook.service in this directory)
#   2. Disable PCIe wakeup on modem's root port RP02 (0000:00:1c.0):
#      echo 'ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:1c.0", ATTR{power/wakeup}="disabled"' \
#        | sudo tee /etc/udev/rules.d/99-lte-wakeup.rules

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
LTE="$SCRIPT_DIR/lte.sh"

STATE_FILE=/run/xmm7360-was-up
PCI_DEV=0000:71:00.0
# Rescan only the modem's root port (RP02), not the whole bus.
# Global rescan can kill the sudo/systemd session by briefly taking down
# NVMe or other PCIe devices during re-enumeration.
RP02=0000:00:1c.0

case "$1" in
    pre)
        if lsmod | grep -q xmm7360; then
            touch "$STATE_FILE"
            "$LTE" down 2>/dev/null || true
            rmmod xmm7360 2>/dev/null || true
        else
            rm -f "$STATE_FILE"
        fi
        # Remove PCIe device so firmware resets cleanly and modem generates
        # no PME/wakeup events during s2idle.
        echo 1 > /sys/bus/pci/devices/$PCI_DEV/remove 2>/dev/null || true
        ;;
    post)
        echo 1 > /sys/bus/pci/devices/$RP02/rescan
        sleep 3
        if [ -f "$STATE_FILE" ]; then
            rm -f "$STATE_FILE"
            modprobe xmm7360 2>/dev/null || true
            # udev auto-bind is unreliable after resume; bind explicitly.
            sleep 1
            echo $PCI_DEV > /sys/bus/pci/drivers/xmm7360/bind 2>/dev/null || true
            # Run lte up in background so GNOME resumes immediately.
            # LTE will connect ~15s after desktop is visible.
            "$LTE" up &>/dev/null &
        fi
        ;;
esac
