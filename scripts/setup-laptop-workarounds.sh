#!/bin/bash
# Installs the machine-specific suspend/resume workarounds this laptop needs
# on top of the upstream driver (see INSTALLING.md / `lte.sh setup`).
#
# These are NOT upstream xmm7360-pci-SPAT behavior — they exist because on
# this Dell + s2idle laptop, the modem independently:
#   1. Storms ACPI GPE 0x6E (~600k events/session), waking the system right
#      back up from s2idle.
#   2. Needs its PCIe device fully removed before suspend and re-probed on
#      resume — a plain driver suspend/resume doesn't clean up its firmware
#      state (see scripts/sleep-hook.sh).
#   3. Livelocks PCI probe if loaded too early in parallel boot, hence the
#      delayed-load unit.
#
# See LAPTOP-WORKAROUNDS.md for the full writeup.
#
# Usage: sudo ./scripts/setup-laptop-workarounds.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root, elevating!"
  exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
EXAMPLES_DIR="$REPO_DIR/examples"

echo "==> Symlinking suspend/resume hook (sleep-hook.sh -> systemd system-sleep)"
chmod +x "$SCRIPT_DIR/sleep-hook.sh"
ln -sf "$SCRIPT_DIR/sleep-hook.sh" /usr/lib/systemd/system-sleep/xmm7360-sleep.sh

echo "==> Installing systemd units (GPE mask, delayed module load)"
install -m 644 "$EXAMPLES_DIR/acpi-mask-gpe6e.service" /etc/systemd/system/acpi-mask-gpe6e.service
install -m 644 "$EXAMPLES_DIR/xmm7360-delayed-load.service" /etc/systemd/system/xmm7360-delayed-load.service
systemctl daemon-reload
systemctl enable --now acpi-mask-gpe6e.service
systemctl enable --now xmm7360-delayed-load.service

echo "==> Installing udev rule to disable PCIe wakeup on the modem's root port"
echo "    (KERNEL address below is this machine's RP02 — verify with lspci if reusing elsewhere)"
install -m 644 "$EXAMPLES_DIR/99-lte-wakeup.rules" /etc/udev/rules.d/99-lte-wakeup.rules
udevadm control --reload-rules

echo "==> Blacklisting xmm7360 from early udev PCI-alias autoload (avoids boot-time livelock)"
install -m 644 "$EXAMPLES_DIR/blacklist-xmm7360-autoload.conf" /etc/modprobe.d/blacklist-xmm7360-autoload.conf

echo "==> Checking kernel cmdline for acpi_mask_gpe=0x6E"
if grep -q "acpi_mask_gpe=0x6E" /proc/cmdline; then
  echo "    already active"
else
  echo "    NOT active. Add acpi_mask_gpe=0x6E to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub,"
  echo "    then run 'update-grub' and reboot."
fi

echo
echo "Done. Reboot recommended so the delayed-load unit and module blacklist take effect cleanly."
