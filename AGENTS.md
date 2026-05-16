# AGENTS.md — xmm7360-pci-SPAT setup notes

This is a local fork/clone of the xmm7360-pci driver, customised for
**Dell XPS 13 5430** (`emils5430`) running Ubuntu 24.04, kernel 6.8,
with an Intel XMM7360 LTE Advanced Modem at PCIe `0000:71:00.0`.

---

## Hardware context

| Item | Value |
|------|-------|
| Machine | Dell XPS 13 5430 |
| Modem | Intel XMM7360 LTE Advanced (PCI `8086:7360`) |
| PCIe address | `0000:71:00.0` |
| Parent root port | RP02 `0000:00:1c.0` |
| Sleep mode | s2idle only (no S3 available on this platform) |
| Kernel | 6.8 (DKMS module signed for Secure Boot) |
| APN | `Surf` (Tele2 SE) |

---

## Installation on this machine

Module is installed via DKMS and signed for Secure Boot. The connection
is managed by `scripts/lte.sh` + `rpc/open_xdatachannel.py`, with a
GTK tray indicator at `/home/eml1/bin/lte-indicator`.

Sudoers entry (NOPASSWD) allows the indicator to call `sudo lte up/down`
without a password prompt.

---

## Scripts overview

### `scripts/lte.sh`

Main management script. Run as root (auto-elevates via pkexec from GUI,
or use `sudo lte <cmd>` from terminal).

| Command | What it does |
|---------|-------------|
| `lte up` | Bind driver if needed, wait for XMM RPC interface, run `open_xdatachannel.py`, bring up wwan0, add fake-wwan NM connection |
| `lte down` | Kill `open_xdatachannel.py`, bring down wwan0, delete fake-wwan NM connection, RST open TCP connections via `ss -K` |
| `lte flr` | PCIe Function Level Reset — resets modem firmware without unloading module. Use when modem is unresponsive but driver is still bound |
| `lte hard-reset` | Full recovery cycle: FLR → rmmod → PCI remove → RP02 rescan → modprobe → bind. Use when `lte up` fails with "XMM RPC interface does not exist" |
| `lte setup` | One-time install: pip deps, symlink to `/usr/local/bin/lte`, build module |

### `rpc/open_xdatachannel.py`

Runs synchronously (not a daemon). With `-d` flag (`--dbus`) it uses
D-Bus to configure NetworkManager with the IP/DNS received from the
modem. Produces verbose RPC debug output. Takes ~15–30s under normal
conditions. Exits when the data channel is set up; two persistent
processes remain in the background holding the modem open
(`runtime_usage = 2`).

### `scripts/sleep-hook.sh`

Template for the systemd sleep hook (see below). Keep in sync with the
deployed file at `/usr/lib/systemd/system-sleep/xmm7360-sleep.sh`.

### `/home/eml1/bin/lte-indicator`

GTK tray indicator (AppIndicator3). Polls `ip route show dev wwan0`
every 2 seconds to determine state. Calls `sudo lte up/down` via
subprocess. Has IPC socket at `~/.cache/lte-indicator/control.sock`
for CLI→daemon commands (`lte-indicator connect/disconnect/toggle/status`).

---

## Suspend/resume setup

s2idle on this machine had two problems:

1. **GPE 0x6E storm** — the modem generates ~600k ACPI GPE 0x6E events
   per session. This wakes the system immediately from s2idle via ACPI
   IRQ 9 (the ACPI SCI). Masked at boot via systemd service.

2. **PCIe PME wakeup via RP02** — even with GPE masked, the modem's
   root port (`0000:00:1c.0`, ACPI name `RP02`) had wakeup enabled and
   forwarded PME events to the system. Disabled via udev rule.

3. **Driver not auto-binding after resume** — after PCIe remove + root
   port rescan, `modprobe xmm7360` loads the module but udev does not
   reliably auto-bind it to the device. The sleep hook explicitly writes
   to `/sys/bus/pci/drivers/xmm7360/bind`.

### Files deployed to the system

| File | Purpose |
|------|---------|
| `/usr/lib/systemd/system-sleep/xmm7360-sleep.sh` | Pre/post suspend hook |
| `/etc/udev/rules.d/99-lte-wakeup.rules` | Disable wakeup on RP02 |
| `/etc/systemd/system/acpi-mask-gpe6e.service` | Mask GPE 0x6E at boot |

### Sleep hook behaviour

**Pre-suspend:**
1. `lte down` (kills `open_xdatachannel.py`, brings down wwan0)
2. `rmmod xmm7360`
3. `echo 1 > /sys/bus/pci/devices/0000:71:00.0/remove` (firmware reset)

**Post-resume:**
1. `echo 1 > /sys/bus/pci/devices/0000:00:1c.0/rescan` (RP02 only — global rescan kills the session)
2. `sleep 3`
3. `modprobe xmm7360`
4. `sleep 1` + explicit bind to `0000:71:00.0`
5. `lte up &` (backgrounded — GNOME desktop resumes immediately, LTE connects ~15s later)

### Why RP02-only rescan

Using `echo 1 > /sys/bus/pci/rescan` (global) briefly takes down all
PCIe devices including NVMe and USB controllers, which kills the
running sudo/systemd-sleep session. The modem is the only device under
RP02, so rescanning only that root port is safe and sufficient.

### Udev rule

```
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:1c.0", ATTR{power/wakeup}="disabled"
```
File: `/etc/udev/rules.d/99-lte-wakeup.rules`

### GPE mask service

File: `/etc/systemd/system/acpi-mask-gpe6e.service`
```
systemctl enable --now acpi-mask-gpe6e.service
```

---

## Known quirks

- **`lte down` must kill `open_xdatachannel.py` first** — the two
  background processes hold `runtime_usage = 2` on the PCI device. If
  they are alive when `rmmod` runs, rmmod blocks in D-state
  (uninterruptible sleep) indefinitely. Only a reboot recovers from this.

- **`rmmod -f` does not help** — force-remove also blocks when the
  driver's `remove()` tries to do firmware cleanup on an unresponsive
  modem. Use `lte flr` first to reset the firmware, then rmmod.

- **`lte up` waits up to 15s for XMM RPC interface** — after
  `modprobe` + explicit bind, the driver's `probe()` does PCIe DMA
  ring setup and firmware handshake before creating `/dev/wwan0xmmrpc0`.
  This takes up to 15s under normal conditions.

- **WiFi briefly loses its GNOME indicator on resume** — likely
  NetworkManager reacting to interface changes during the LTE bring-up.
  Mitigated by running `lte up` in the background from the sleep hook.

---

## Changelog

### 2026-05-16

**Suspend/resume fix** (commit `7c0a647`)

- `lte down`: kill `open_xdatachannel.py` before taking interface down
  so `rmmod` succeeds.
- `lte up`: explicit PCIe driver bind after modprobe; wait up to 15s
  for `/dev/wwan0xmmrpc0` before running `open_xdatachannel.py`.
- New `lte flr`: PCIe Function Level Reset for firmware recovery.
- New `lte hard-reset`: full cycle (FLR + rmmod + PCI remove + RP02
  rescan + modprobe + bind) for when modem is fully unresponsive.
- `scripts/sleep-hook.sh`: use RP02 root port rescan instead of global;
  run `lte up` in background so GNOME resumes immediately.
- Deployed system files: sleep hook, udev rule, GPE mask service.
