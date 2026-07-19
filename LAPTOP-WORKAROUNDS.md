# Laptop-specific suspend/resume workarounds

This is separate from [INSTALLING.md](INSTALLING.md). That covers the
upstream driver/binary install (`lte.sh setup`). This covers extra
machine-specific workarounds this Dell laptop (s2idle-only suspend) needs to
suspend and resume cleanly with the XMM7360 modem installed — none of this is
upstream xmm7360-pci-SPAT behavior.

## Why

On this machine, the modem independently:

1. **Storms ACPI GPE 0x6E** (~600k events/session) as soon as the system
   suspends, waking it right back up under s2idle. Masking that GPE
   (`acpi-mask-gpe6e.service` + the `acpi_mask_gpe=0x6E` kernel boot param)
   stops it at the source.
2. **Doesn't survive a plain suspend/resume.** A normal driver suspend leaves
   the modem's firmware in a state the driver can't recover from on resume.
   `scripts/sleep-hook.sh` works around this by fully removing the PCIe
   device before suspend and re-probing + reloading the driver after resume.
3. **Livelocks PCI probe if loaded too early** during parallel boot (see
   `xmm7360-delayed-load.service`), so it's blacklisted from udev's normal
   PCI-alias autoload and loaded once `graphical.target` is reached instead.

## Install

```
sudo ./scripts/setup-laptop-workarounds.sh
```

This installs/enables:

- `scripts/sleep-hook.sh` → symlinked to `/usr/lib/systemd/system-sleep/xmm7360-sleep.sh`
  (symlinked, not copied, so it keeps resolving `lte.sh` correctly if this repo moves)
- `examples/acpi-mask-gpe6e.service` → `/etc/systemd/system/`, enabled
- `examples/xmm7360-delayed-load.service` → `/etc/systemd/system/`, enabled
- `examples/99-lte-wakeup.rules` → `/etc/udev/rules.d/` (disables PCIe wakeup
  on the modem's root port — the PCI address in this rule is specific to this
  machine; verify with `lspci` before reusing it elsewhere)
- `examples/blacklist-xmm7360-autoload.conf` → `/etc/modprobe.d/`

It also checks (but doesn't modify) whether `acpi_mask_gpe=0x6E` is on the
kernel cmdline — add it to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`
and run `update-grub` if it's missing.

Run once, then reboot.

## Debugging a failed resume

`scripts/sleep-hook.sh`'s post-resume `lte up` logs to
`/var/log/xmm7360-resume.log` — check there first if the modem doesn't come
back after resume.
