# AGENTS.md — xmm7360-pci-SPAT setup notes

This is a local fork/clone of the xmm7360-pci driver, customised for
**Dell XPS 13 5430** running Ubuntu 24.04, kernel 6.8,
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
GTK tray indicator at `~/bin/lte-indicator`.

Sudoers entry (NOPASSWD) allows the indicator to call `sudo lte up/down`
without a password prompt.

---

## Installing the suspend/resume tweaks

These steps are required **in addition to** the standard install in
`INSTALLING.md`. They make s2idle work correctly with the modem on this
Dell XPS / Alder Lake platform.

### Prerequisites

- `lte setup` already completed (module built, `lte` symlinked to
  `/usr/local/bin/lte`, `xmm7360.ini` configured)
- Running from the repo root: `cd ~/slask/claude-slask/lte/xmm7360-pci-SPAT`

### Step 1 — Sleep hook

Copies `scripts/sleep-hook.sh` to the systemd hook directory.

```bash
sudo cp scripts/sleep-hook.sh /usr/lib/systemd/system-sleep/xmm7360-sleep.sh
sudo chmod +x /usr/lib/systemd/system-sleep/xmm7360-sleep.sh
```

### Step 2 — Disable PCIe wakeup on modem's root port

Prevents the modem's root port (RP02) from forwarding PME events that
wake the system from s2idle.

```bash
echo 'ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:00:1c.0", ATTR{power/wakeup}="disabled"' \
  | sudo tee /etc/udev/rules.d/99-lte-wakeup.rules
sudo udevadm control --reload-rules
```

### Step 3 — Mask the ACPI modem wake GPEs 0x6E and 0x6F

The modem generates ~600k ACPI GPE 0x6E interrupts per session. Dell's DSDT
also maps GPE 0x6F to `Notify (RP02, Device Wake)`. Either can wake s2idle, so
this service masks both at every boot.

```bash
sudo tee /etc/systemd/system/acpi-mask-gpe6e.service << 'EOF'
[Unit]
Description=Mask ACPI GPE 0x6E and RP02 wake GPE 0x6F from Intel XMM7360 LTE modem
After=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo mask > /sys/firmware/acpi/interrupts/gpe6E; echo mask > /sys/firmware/acpi/interrupts/gpe6F'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now acpi-mask-gpe6e.service
```

### Step 4 — Sudoers entry for passwordless lte up/down

Required for the tray indicator and the sleep hook to call `lte` as
root without a password prompt.

```bash
sudo tee /etc/sudoers.d/lte << 'EOF'
# Allow lte-indicator and sleep hook to manage LTE without password
<username> ALL=(root) NOPASSWD: /usr/local/bin/lte
EOF
sudo chmod 440 /etc/sudoers.d/lte
```

### Verify

After a reboot:

```bash
# GPE should be masked
cat /sys/firmware/acpi/interrupts/gpe6E   # expect: disabled
cat /sys/firmware/acpi/interrupts/gpe6F   # expect: disabled

# Root port wakeup should be disabled
cat /sys/bus/pci/devices/0000:00:1c.0/power/wakeup   # expect: disabled

# Modem should connect normally
lte up
lte-indicator status   # expect: connected
```

Then test suspend: `systemctl suspend`. On resume the modem should
reconnect automatically within ~15 seconds.

---

## Scripts overview

### `scripts/lte.sh`

Main management script. Run as root (auto-elevates via pkexec from GUI,
or use `sudo lte <cmd>` from terminal).

| Command | What it does |
|---------|-------------|
| `lte up` | Bind driver if needed, wait for XMM RPC interface, run `open_xdatachannel.py`, bring up wwan0, add fake-wwan NM connection, verify traffic actually passes. Self-heals once (hard-reset + retry) on any failure, including a link that came up but has no connectivity |
| `lte down` | Kill `open_xdatachannel.py`, bring down wwan0, delete fake-wwan NM connection, RST open TCP connections via `ss -K` |
| `lte flr` | PCIe Function Level Reset — resets modem firmware without unloading module. Use when modem is unresponsive but driver is still bound |
| `lte hard-reset` | Full recovery cycle: FLR → rmmod → PCI remove → RP02 rescan → modprobe → bind. Use when `lte up` fails with "XMM RPC interface does not exist" |
| `lte setup` | One-time install: pip deps, symlink to `/usr/local/bin/lte`, build module |

`up`, `hard-reset`, and `flr` acquire an `flock` on `/run/lock/xmm7360-lte.lock` (10 min wait) before touching driver/interface state, so concurrent invocations (e.g. the sleep hook's post-resume `lte up` and lte-indicator's own D-Bus wake handler firing seconds apart) serialize instead of racing each other. `down` deliberately does **not** wait on this lock — a post-resume cellular re-attach inside a stuck-looking `up` can genuinely take minutes, and `down`'s `pkill -f open_xdatachannel.py` is the only way to cancel it; it's meant to interrupt an in-flight `up`, not queue behind it.

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

### `~/bin/lte-indicator`

GTK tray indicator (AppIndicator3). Polls `ip route show dev wwan0`
every 2 seconds to determine state. Calls `sudo lte up/down` via
subprocess. Has IPC socket at `~/.cache/lte-indicator/control.sock`
for CLI→daemon commands (`lte-indicator connect/disconnect/toggle/status`).

---

## Suspend/resume setup

s2idle on this machine had two problems:

1. **GPE 0x6E storm and GPE 0x6F device wake** — the modem generates ~600k
   GPE 0x6E events per session, while Dell's DSDT maps GPE 0x6F to an RP02
   `Device Wake` notification. Both wake s2idle via ACPI IRQ 9 and are masked
   at boot via the systemd service.

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
| `/etc/systemd/system/acpi-mask-gpe6e.service` | Mask modem GPEs 0x6E and 0x6F at boot |

### Sleep hook behaviour

**Pre-suspend:**
1. Terminate the Kismet/GPS reader and stop `xmm7360-kismet-gps.service`
   explicitly (systemd runs sleep hooks in parallel, and the user manager may
   already be frozen, so its separate hook alone cannot provide ordering).
2. `lte down` (kills `open_xdatachannel.py`, brings down wwan0, removes the
   NetworkManager connection, and resets sockets using the LTE source address).
3. Wait up to five seconds for all `/dev/xmm0/*` and `/dev/wwan0*` users to
   close. If they remain open, skip destructive teardown.
4. PCI function-level reset to stop modem firmware and DMA, then wait one
   second.
5. `rmmod xmm7360`; only on success, remove PCI device `0000:71:00.0`.

The fail-safe paths deliberately leave the disconnected modem present. That
may cause an immediate wake on this hardware, but is safer than unloading the
driver while the modem can still DMA and crashing the kernel.

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

- **Two independent triggers race `lte up` after resume** — the systemd
  sleep hook backgrounds `lte up` right after rescan/modprobe, and
  lte-indicator's own D-Bus `PrepareForSleep` listener separately calls
  `sudo lte up` ~8s after wake. Without serialization these can interleave
  mid rmmod/modprobe/PCI-remove-rescan. Confirmed live via journalctl
  2026-08-03: a `sudo lte up` session stayed open 3.5 minutes while two
  separate `sudo lte down` invocations ran concurrently against it.
  `lte.sh`'s `up`/`hard-reset`/`flr` now hold an `flock` so a second
  automatic trigger waits instead of interleaving; `down` deliberately does
  not wait on it (see the `lte.sh` command table above).

- **A post-resume cellular re-attach can take minutes, not seconds** —
  confirmed live 2026-08-03: `open_xdatachannel.py` streamed continuous RPC
  traffic for 3.5 minutes before either succeeding or being interrupted, well
  past the ~15-30s normally expected. This isn't a hang; the modem is
  genuinely still re-registering with the tower. lte-indicator's "connecting"
  icon state must not be driven by a short fixed timer, or it flips back to
  "disconnected" while `lte up` is still legitimately working, which is what
  tempts a manual disconnect/reconnect that races the in-flight attempt
  instead of waiting it out. Fixed by having the indicator check whether
  `lte.sh`'s lock is actually held (`lte_busy()`) rather than guessing a
  duration.

---

## Changelog

### 2026-08-07

**Safe pre-suspend LTE teardown**

- Root-caused two machine hangs (2026-08-01 and 2026-08-07) as XMM7360 DMA
  writes into already-unmapped memory during driver teardown. The latter
  happened after logind requested sleep but before `PM: suspend entry`, which
  left the laptop powered with a dead kernel and looked like a failed wake.
- `scripts/sleep-hook.sh` now stops the Kismet/GPS reader in the same ordered
  hook as LTE teardown, waits for all modem device-node users to close, and
  performs PCI FLR before `rmmod` frees the driver's DMA rings.
- If readers do not close, FLR fails, or `rmmod` fails, PCI removal is skipped
  instead of risking another kernel crash.
- Follow-up after three real suspend attempts: each entered s2idle but woke
  after 32–40 seconds via ACPI IRQ 9. GPE counters and DSDT disassembly
  identified GPE 0x6F as `Notify (RP02, Device Wake)`. The boot service now
  masks 0x6F as well as 0x6E. Driver teardown also treats a module already
  unloaded by a concurrent helper as success and continues PCI removal.

### 2026-08-03

**Self-heal robustness fix** (branches `lte-selfheal-followup` /
`lte-selfheal`, revised after live suspend/resume testing on this machine)

- `lte.sh`: `up`, `hard-reset`, and `flr` now serialize on an `flock`
  (`/run/lock/xmm7360-lte.lock`, 10 min wait) so the sleep hook's post-resume
  `lte up` and lte-indicator's independent wake-triggered `lte up` can't race
  each other and corrupt shared driver/interface state. `down` deliberately
  stays outside the lock — live testing confirmed a post-resume re-attach can
  take minutes, and `down`'s `pkill -f open_xdatachannel.py` needs to be able
  to interrupt a still-running `up`, not queue behind it.
- `bring_up()`: verify actual connectivity (`ping` via `wwan0`) after
  nmcli reports the connection up, not just that `open_xdatachannel.py`
  exited 0. A link that comes up looking fine but passes no traffic now
  counts as a bring-up failure, so the existing hard-reset-and-retry
  self-heal (2026-07-09) fires automatically instead of requiring a
  manual disconnect/reconnect cycle to notice and clear it.
- `lte-indicator`: the "connecting" icon state now checks whether
  `lte.sh`'s lock is actually held (`lte_busy()`) instead of guessing a
  fixed duration — a real post-resume attach was observed running 3.5
  minutes, far past any timer that was tried, so a fixed timeout kept
  flipping the icon back to "disconnected" mid-attempt.

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
