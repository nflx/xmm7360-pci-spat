#!/bin/bash
# Systemd sleep hook for xmm7360 LTE modem.
# Unloads the driver before suspend so the PCIe device goes quiet
# (no PME wakeup events). Reloads and reconnects after resume.
#
# Install: sudo ln -s /full/path/to/sleep-hook.sh /usr/lib/systemd/system-sleep/xmm7360-sleep.sh
#          sudo chmod +x sleep-hook.sh
# Symlink, not a copy — resolves lte.sh via its own real path (readlink -f "$0"),
# so it keeps working if this repo ever moves. A copy drifted stale before.
#
# Also required for suspend to work (Dell XPS + XMM7360):
#   1. Mask ACPI GPE 0x6E storm and RP02 wake GPE 0x6F from modem:
#      sudo systemctl enable --now acpi-mask-gpe6e.service
#      (see sleep-hook.service in this directory)
#   2. Disable PCIe wakeup on modem's root port RP02 (0000:00:1c.0):
#      echo 'ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:1c.0", ATTR{power/wakeup}="disabled"' \
#        | sudo tee /etc/udev/rules.d/99-lte-wakeup.rules

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
LTE="$SCRIPT_DIR/lte.sh"

STATE_FILE=/run/xmm7360-was-up
LOG_FILE=/var/log/xmm7360-resume.log
PCI_DEV=0000:71:00.0
PCI_SYSFS=/sys/bus/pci/devices/$PCI_DEV
GPS_USER=eml1
GPS_UID=1000
GPS_SERVICE=xmm7360-kismet-gps.service
# Rescan only the modem's root port (RP02), not the whole bus.
# Global rescan can kill the sudo/systemd session by briefly taking down
# NVMe or other PCIe devices during re-enumeration.
RP02=0000:00:1c.0

log() {
    echo "$(date -Is) $*" >>"$LOG_FILE"
}

stop_gps_reader() {
    local runtime=/run/user/$GPS_UID

    # The user manager can be frozen by the time system-sleep hooks run, so
    # terminate the reader directly first. It handles SIGTERM and closes the
    # modem nodes; stopping the unit as well prevents a later restart.
    pkill -TERM -f '/xmm7360_kismet_nmea_tcp.py' 2>/dev/null || true

    if [ -S "$runtime/bus" ]; then
        XDG_RUNTIME_DIR="$runtime" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
            timeout 2s runuser -u "$GPS_USER" -- \
            systemctl --user stop "$GPS_SERVICE" >>"$LOG_FILE" 2>&1 || true
    fi
}

modem_has_users() {
    local node

    for node in /dev/xmm0/* /dev/wwan0*; do
        [ -e "$node" ] || continue
        if fuser "$node" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

wait_for_modem_users() {
    local attempt

    for attempt in $(seq 1 20); do
        modem_has_users || return 0
        sleep 0.25
    done
    return 1
}

case "$1" in
    pre)
        if lsmod | grep -q xmm7360; then
            touch "$STATE_FILE"
            # systemd runs all system-sleep hooks concurrently. Stop the GPS
            # reader here as well so its separate hook cannot race rmmod.
            stop_gps_reader
            "$LTE" down 2>/dev/null || true

            if ! wait_for_modem_users; then
                log "pre-$2: modem device nodes are still in use; skipping driver/PCI removal"
                exit 0
            fi

            # Quiesce modem firmware/DMA before the driver frees coherent DMA
            # rings. Without this FLR, the device has twice DMA-written into
            # unmapped memory during teardown and crashed the kernel.
            if [ ! -w "$PCI_SYSFS/reset" ] || ! echo 1 >"$PCI_SYSFS/reset"; then
                log "pre-$2: PCI function reset failed; skipping driver/PCI removal"
                exit 0
            fi
            sleep 1

            # A concurrent recovery or sleep helper may already have unloaded
            # the module. Treat that as the desired state, not as a teardown
            # failure that prevents PCI removal.
            if lsmod | grep -q '^xmm7360 '; then
                if ! rmmod xmm7360; then
                    log "pre-$2: rmmod failed; skipping PCI removal"
                    exit 0
                fi
            fi
        else
            rm -f "$STATE_FILE"
        fi
        # Remove PCIe device so firmware resets cleanly and modem generates
        # no PME/wakeup events during s2idle.
        echo 1 > "$PCI_SYSFS/remove" 2>/dev/null || true
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
            { echo "=== $(date -Is) resume: lte up ==="; "$LTE" up; } >>"$LOG_FILE" 2>&1 &
        fi
        ;;
esac
