# Ember

A native macOS menu bar monitor with an animated thermal indicator, clear temperature readings, app activity estimates, and optional fan control.

Requires macOS 14 or later. No network requests, analytics, or third-party runtime dependencies.

## Install and run

Download the Apple Silicon release ZIP from [Releases](https://github.com/SomaadityaSamal/Ember/releases), verify its SHA-256 checksum, and move `Ember.app` to `/Applications`. Launch it and click the Ember indicator for the dashboard. The current binary is arm64; Intel Macs require a source build. Source builds require Swift 6 or newer and Xcode or Command Line Tools:

```sh
./scripts/build-app.sh
open build/Ember.app
```

The preview release is ad-hoc signed and not notarized. Gatekeeper may require the user's explicit approval according to local macOS policy. Ember never changes Gatekeeper, SIP, or other security settings. To build with your own signing identity, supply `EMBER_SIGNING_IDENTITY` locally; never commit private signing material.

Ad-hoc helper updates can require a new background-item approval because they lack a stable Developer ID identity. macOS lists this permission under **Ember**, not necessarily under a separate fan-helper name. A registration error is not itself proof that approval is missing; Ember reports the actual error and offers repair.

## Temperatures that mean what they say

The default number is **CPU average**, using the same selected CPU-core sensor keys as Stats on supported M1–M5 chips. Stats' own CPU reader averages those sensors. Settings also offer hottest CPU core, hottest CPU/GPU/SoC, or an individual sensor. Separate polling times, sensor availability, Stats versions, and a different selected Stats sensor can still produce differences.

Earlier Ember builds displayed the hottest sensor across a wider set of CPU/GPU/SoC keys. Comparing that peak with Stats' CPU average could show a large difference. Both represent different measurements; the new source selector makes the distinction explicit.

The thermal state, peak history chart, and fan temperature trigger use the hottest CPU/GPU/SoC sensor. The main display may therefore show a cooler CPU average while the state is hot. Raw sensor keys are available in Sensor details. Unsupported chips do not receive invented CPU-core mappings.

Cool is below 65°C, warm starts at 65°C, and hot starts at 85°C, with a 5°C recovery margin. macOS thermal pressure can raise the state. These are awareness thresholds, not hardware safety limits. Missing sensors display a dash.

## What is keeping your Mac busy?

Ember groups bundled helpers with their app, and non-bundled children with the nearest sampled app ancestor. Explore all activity to search by name or PID and filter apps or background work. Expand a row to inspect memory and process IDs or force quit, after confirmation.

CPU uses Activity Monitor's convention: 100% means one busy logical core. Process Mach CPU-time counters are converted to nanoseconds before calculating interval usage.

**Estimated heat share** is a group's share of CPU time across readable processes during the latest interval. It is not a measured fraction of heat, watts, or energy. GPU/ANE work, charging, display, disk/network power, core differences and thermal lag are not attributed. Sampling coverage is shown; macOS blocks access to some processes.

Background activity means an app is not frontmost, not that it is unused. Ember flags a background group using at least 20% CPU, or any group using at least 100%, for at least 30 seconds. Builds, media playback and indexing may legitimately qualify.

## Fan controls

The animated fan inside Ember’s dashboard cycles **Auto → Max → Temperature** after the optional helper is enabled. Temperature mode has a configurable 45–100°C threshold and returns to Auto 5°C below it. The trigger uses peak temperature, independent of the displayed source. The chosen polling interval determines temperature reaction time.

1. Return any other fan controller to Auto and quit it. Ember checks for Macs Fan Control to avoid competing controllers.
2. Click **Enable…** in Ember's fan panel. Approve the root fan helper using macOS' Background Items / Login Items controls and administrator authentication if requested. Ember never asks for or stores your password.
3. Click **Connect** or **Enable…** again after approval. The UI reports a confirmed connection or the actual error. Monitoring continues if fan control is unavailable.
4. Click the fan to cycle modes. **Auto** keeps macOS in charge; **Max** requests every fan's firmware-reported maximum. The threshold can be changed in Temperature mode.
5. Use **Remove fan helper** in Settings to restore automatic control and unregister it.

Non-automatic modes are session-only. A connection loss, expired heartbeat, pause, stale sample, sleep or normal shutdown requests automatic control. SMC writes are hardware-dependent and undocumented; fan control is experimental until verified on the target hardware. The project does not bundle or automate Macs Fan Control. See [security safeguards and limitations](SECURITY.md).

## Polling and performance

Choose **5, 15 or 30 seconds** in Settings. The default is 5 seconds; old unsupported preferences migrate to 5. The orbit, flame pulse, fan rotation and menu indicator use continuous Core Animation on cached layers, independently of sensor polling. Animation honors Reduce Motion and can be disabled; the popover's animation pauses while closed. Fan control, while connected, adds a lightweight 10-second heartbeat and a one-second helper watchdog; it does not repeatedly enumerate processes on that heartbeat.

Monitoring enumerates processes and reads supported SMC sensors on a serial utility queue. Longer polling intervals reduce that work. The dashboard and animation add drawing and compositing work; Max fan mode itself uses more fan power. Performance depends on process count, sampling interval, macOS and hardware; measurements and their method are documented in [performance notes](docs/PERFORMANCE.md).

## Build, test and inspect

```sh
./scripts/test.sh
./scripts/build-app.sh
python3 scripts/privacy-audit.py
python3 scripts/privacy-audit.py --app build/Ember.app
```

Find the architecture-specific binary using `swift build --build-system native --show-bin-path`. The native backend accommodates standalone Command Line Tools installations. An alias disambiguates the SwiftUI State property wrapper from newer SDK macros.

`Ember --diagnose` is an opt-in local diagnostic that prints sensor values and process/app names, then exits. Never attach its raw output publicly without reviewing it. `--snapshot /absolute/path.png` is a local development screenshot tool; real process screenshots are excluded from releases.

The root helper refuses unprivileged or unpinned execution. Standalone `swift build` produces an unpinned development helper that cannot control hardware; `build-app.sh` assembles and signs the client and embeds its exact public signing identity in the helper. Moving or updating an enabled helper bundle may require removal and re-registration in macOS Settings. Keep only one installed Ember copy when enabling fan control.

## References

- [Stats CPU temperature reader](https://github.com/exelban/stats/blob/master/Modules/CPU/readers.swift) and [sensor mappings](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift) document the core-key selections and averaging behavior. No Stats source or binary is bundled.
- [VirtualSMC sensor-key documentation](https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt) describes SMC key conventions.
- [Apple Service Management](https://developer.apple.com/documentation/servicemanagement/smappservice) provides user-approved helper registration.
- [Apple Silicon fan-control research](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md) describes mode-key casing, firmware maximums, and the diagnostic unlock sequence. Ember uses an independent, bounded implementation.
- [Macs Fan Control's documented command line](https://crystalidea.com/macs-fan-control/command-line) does not provide fan-speed control commands.
