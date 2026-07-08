# SafeHalt

A tiny native-Swift macOS shutdown daemon for network UPS (NUT) — safely powers your Mac down when the UPS runs low, **without depending on Homebrew or `upsmon`**. Ships as the `safehalt` binary.

SafeHalt talks the NUT protocol directly to your NAS/server's `upsd`, and when mains has been out long enough (or the battery is critically low) it runs `/sbin/shutdown`. It is designed for the common home setup where a UPS is plugged into a NAS (Synology/QNAP/…) over USB, the NAS exposes NUT over the network, and a Mac that has *no* direct UPS connection needs to shut down safely on a power failure.

> ⚠️ **This daemon will power off your Mac.** Read the safety notes below and test with `--dry-run` before you rely on it.

## Why

Most macOS UPS tools either only *monitor* (never shut down) or lean on Homebrew's `upsmon`, whose config is fiddly and whose root process can't show a user-visible warning (macOS blocks a root LaunchDaemon from the login GUI). `safehalt` is self-contained: one small binary, one JSON config, native NUT client, and the correct root-daemon / user-session split for notifications.

## Design & safety

The safety-critical decision is a **pure function** (`ShutdownDecider`) — given the UPS status, how long it's been on battery, the comm-loss timer, the policy, and the cancel flag, it returns exactly one of *nothing / start countdown / cancel / shut down now*. Because it has no I/O, it is exhaustively unit-tested.

Iron rules enforced in code and tests:

- **Shutdown is never blocked by a notification.** `shutdown()` is an unconditional `/sbin/shutdown -h now`; every osascript notification/dialog is fire-and-forget and can never gate the shutdown (a hung TCC prompt or absent login session can't stall protection).
- **`--dry-run` cannot shut down.** It logs the decision instead — used to validate the full chain against a real UPS without powering off.
- **Low battery shuts down immediately**, overriding a pending cancel — but only when mains is *not* confirmed online (so an `OL LB` "recovering-and-recharging" state does not trigger a shutdown/boot loop).
- **Communication loss is handled conservatively.** If comms drop *during* a countdown, the countdown continues (last known state was on-battery). If comms drop while idle, a shutdown only happens after a configurable failsafe window (minute-granularity, `0` disables it) — never a hair-trigger, so a routine NAS reboot won't power your Mac off.
- **The countdown is cancelable.** On battery, the daemon shows a user-session dialog (via `launchctl asuser`) with a "cancel (at your own risk)" button that stays up for the whole countdown; ignoring it lets the shutdown proceed.

## Requirements

- macOS 13+
- A network UPS server (NUT `upsd`) reachable on your LAN — e.g. Synology DSM's "Network UPS server", QNAP's UPS support, or any Linux box running `nut`.
- Swift toolchain (Xcode or Command Line Tools) to build.

No Homebrew, no `nut` package on the Mac.

## Build & test

```bash
swift build -c release --product safehalt
./test.sh           # runs the unit suite (Swift Testing)
```

`test.sh` wraps `swift test` with the framework paths needed when only Command Line Tools (no Xcode) are installed.

Real-server integration tests are skipped unless you point them at a UPS:

```bash
SAFEHALT_NUT_HOST=192.168.1.100 SAFEHALT_NUT_USER=monuser SAFEHALT_NUT_PASS=yourpass \
  ./test.sh --filter NUTSocketSessionIntegrationTests
```

## Configure

Create a `config.json`:

```json
{
  "host": "192.168.1.100",
  "port": 3493,
  "ups": "ups",
  "username": "monuser",
  "password": "your-nut-monitor-password",
  "onBatteryMinutes": 10,
  "shutdownAlsoOnLowBattery": true,
  "commLossFailsafeMinutes": 5,
  "pollSeconds": 5
}
```

- `onBatteryMinutes` — shut down after this many minutes on battery (must be ≥ 1).
- `shutdownAlsoOnLowBattery` — also shut down immediately when the UPS reports low battery.
- `commLossFailsafeMinutes` — if the daemon can't reach the UPS this long while idle, treat it as a suspected outage and start the countdown. `0` disables the failsafe. Set it comfortably longer than a normal NAS reboot.
- `pollSeconds` — poll interval.

## Try it safely first

```bash
swift build -c release --product safehalt
.build/release/safehalt --config ./config.json --dry-run
```

Watch the log: on mains-normal it does nothing; it will print what it *would* do without ever shutting down.

## Install / uninstall (root LaunchDaemon)

```bash
./install-daemon.sh ./config.json      # one admin-password prompt; loads a root LaunchDaemon
./uninstall-daemon.sh                  # stops and removes it, no orphan left behind
```

Installed layout:

| Path | |
|---|---|
| `/usr/local/bin/safehalt` | the binary |
| `/Library/Application Support/SafeHalt/config.json` | config (mode `600`) |
| `/Library/LaunchDaemons/com.safehalt.daemon.plist` | LaunchDaemon (`RunAtLoad` + `KeepAlive`) |
| `/var/log/safehalt.log` | log |

Cancel a countdown from the command line (also writable by the daemon's own dialog):

```bash
safehalt cancel        # writes /tmp/safehalt-cancel-shutdown; honored before the shutdown fires
```

## Notes & limitations

- The NUT monitor password is stored in a root-only (`600`) JSON file. It's a LAN-scoped monitor credential, but treat it accordingly.
- `safehalt` is a from-scratch shutdown engine; it does not carry every edge case decades of `upsmon` handle (its comm-loss behavior is the conservative failsafe described above rather than `upsmon`'s `DEADTIME`).
- The privileged install uses `osascript` elevation; the password dialog shows "osascript". A signed `.pkg` installer (branded name) is the proper distribution path and is not yet included.

## License

MIT — see [LICENSE](LICENSE).
