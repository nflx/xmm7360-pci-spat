#!/bin/bash
# Systemd sleep hook for xmm7360 LTE modem.
# Unloads the driver before suspend so the PCIe device goes quiet
# (no PME wakeup events). Reloads and reconnects after resume.
#
# Install:
#   sudo cp scripts/sleep-hook.sh /usr/lib/systemd/system-sleep/xmm7360-sleep.sh
#   sudo chmod +x /usr/lib/systemd/system-sleep/xmm7360-sleep.sh
#
# Additional steps that may be needed to prevent spurious wakeups:
#
# 1. Disable PCIe PME wakeup on the modem's root port (find with lspci -tv):
#    echo 'ACTION=="add", SUBSYSTEM=="pci", KERNEL=="<RP-addr>", ATTR{power/wakeup}="disabled"' \
#      | sudo tee /etc/udev/rules.d/99-lte-wakeup.rules
#    sudo udevadm control --reload-rules
#
# 2. Mask ACPI GPE storm from the modem (if the modem generates many GPE
#    events per session, check with: cat /sys/firmware/acpi/interrupts/gpe*):
#    sudo tee /etc/systemd/system/acpi-mask-gpeXX.service << 'EOF'
#    [Unit]
#    Description=Mask ACPI GPE storm from XMM7360 LTE modem
#    After=systemd-udevd.service
#    [Service]
#    Type=oneshot
#    ExecStart=/bin/sh -c 'echo disable > /sys/firmware/acpi/interrupts/gpeXX'
#    RemainAfterExit=yes
#    [Install]
#    WantedBy=multi-user.target
#    EOF
#    sudo systemctl enable --now acpi-mask-gpeXX.service

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
LTE="$SCRIPT_DIR/lte.sh"

STATE_FILE=/run/xmm7360-was-up
PCI_INFO_FILE=/run/xmm7360-pci-info

case "$1" in
    pre)
        # Detect PCI device and its parent root port before removing the device.
        # Store them so the post hook can use them after the device is gone.
        PCI_DEV=$(lspci -D 2>/dev/null | awk '/8086:7360/{print $1; exit}')
        if [ -n "$PCI_DEV" ] && [ -e "/sys/bus/pci/devices/$PCI_DEV" ]; then
            RP=$(readlink /sys/bus/pci/devices/$PCI_DEV 2>/dev/null \
                | sed 's|.*/\([^/]*\)/[^/]*$|\1|')
            echo "$PCI_DEV $RP" > "$PCI_INFO_FILE"
        fi

        if lsmod | grep -q xmm7360; then
            touch "$STATE_FILE"
            "$LTE" down 2>/dev/null || true
            rmmod xmm7360 2>/dev/null || true
        else
            rm -f "$STATE_FILE"
        fi
        # Remove PCIe device so firmware resets cleanly and modem generates
        # no PME/wakeup events during suspend.
        [ -n "$PCI_DEV" ] && echo 1 > /sys/bus/pci/devices/$PCI_DEV/remove 2>/dev/null || true
        ;;
    post)
        # Read stored PCI info (device was removed during pre, not visible now)
        if [ -f "$PCI_INFO_FILE" ]; then
            read PCI_DEV RP < "$PCI_INFO_FILE"
        fi

        # Rescan only the modem's root port, not the whole bus.
        # Global rescan can briefly take down NVMe/USB PCIe devices and kill
        # the running sudo/systemd-sleep session.
        if [ -n "$RP" ]; then
            echo 1 > /sys/bus/pci/devices/$RP/rescan
        fi
        sleep 3

        if [ -f "$STATE_FILE" ]; then
            rm -f "$STATE_FILE"
            modprobe xmm7360 2>/dev/null || true
            # udev auto-bind is unreliable after resume; bind explicitly.
            sleep 1
            [ -n "$PCI_DEV" ] && echo $PCI_DEV > /sys/bus/pci/drivers/xmm7360/bind 2>/dev/null || true
            # Run lte up in background so the desktop resumes immediately.
            # LTE will connect ~15s after the desktop is visible.
            "$LTE" up &>/dev/null &
        fi
        ;;
esac
