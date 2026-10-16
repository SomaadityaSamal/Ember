# Security and privacy

Ember does not make network requests, include analytics, or upload sensor/process information. Only display and polling preferences and the fan temperature threshold are saved in local UserDefaults. Process history is held in memory for the current session; temperature history expires after five minutes.

## Privilege boundaries

The menu bar app and fan client run as the logged-in user. Monitoring needs no administrator access. Process termination is limited to the current user's processes, with a confirmation and a fresh PID/start-time check; protected services and Ember itself are excluded. As with PID-based operating-system APIs, identity lookup and signaling are separate operations and cannot be atomic. This feature does not elevate privileges.

Fan control is optional. macOS Service Management registers an in-bundle root helper only when the user explicitly enables it and approves the system permission. It exposes a single typed RPC accepting a Boolean: firmware maximum, or restore automatic control. It accepts no command strings, executable paths, arbitrary SMC keys, custom RPMs, or file-writing requests. The helper contains no shell execution or network server.

The helper accepts one connection from the current console user. NSXPC enforces the exact code-signing hash of the small, independently signed fan client, embedded in the helper's read-only Mach-O data at build time. The client verifies the enclosing app's sealed bundle and validates the helper's exact designated signing requirement before connecting. The client uses private inherited stdin/stdout pipes to the unprivileged GUI. The public signing hashes are code identities, not credentials or private signing keys. A helper update must be registered again after replacing the app; a different client build fails closed.

A copy of the approved, unmodified fan client can request the same two bounded operations as the GUI for that console user. This is intentional; the helper does not confer arbitrary root execution. Ad-hoc builds have no stable vendor identity across builds. Developer ID signing and notarization are recommended for general distribution.

## Fan safeguards and limits

- Fresh fan count, mode, and firmware maximum readings are validated before taking control. Existing manual control is rejected. The UI also refuses acquisition while Macs Fan Control is running.
- Writes are internally restricted to fan-mode, fan-target, legacy fan-mask, and fan diagnostic-unlock keys. Manual target values always come from validated firmware maximums; no zero, reduced, or user-specified target RPM is offered.
- macOS normally controls all fans. Non-automatic modes are never restored automatically on app startup.
- The helper verifies the requested mode and target, rather than treating a successful write as proof. A failure triggers restoration.
- A 10-second GUI heartbeat renews a 45-second helper lease. A lost client connection, expired lease, app pause, stale/missing temperature sample, sleep, normal app exit, or normal helper termination requests automatic control. Failed restoration is retried by the helper.
- Temperature mode uses the peak CPU/GPU/SoC reading, independent of the displayed sensor, with a 5°C recovery margin. Reaction time is bounded by the chosen 5/15/30-second polling interval while the system is awake and scheduling normally.
- SMC is undocumented. Hardware/OS restrictions can prevent control or restoration. An uncatchable kill of the root helper, power loss, or kernel failure cannot run its cleanup code; a successful Auto request or reboot may be needed. No claim is made that software overrides preserve every Apple thermal policy. Max mode can increase noise and power consumption.
- Do not run competing fan controllers. Fanless and unsupported Macs keep monitoring available and report unavailable fan control.

## Release hygiene

Release packaging uses an allowlist and includes only the app, a checksum, and public documentation. Local diagnostics, screenshots showing real apps, process lists, preferences, Keychains, provisioning profiles, signing keys, build caches, and debug symbols are excluded. Compiler path remapping and symbol stripping remove local workspace paths from release executables. Git commits use a GitHub noreply address.

The automated privacy scan checks source text and packaged files for credential patterns, local home-directory paths, secret filenames, forbidden bundle contents, and runtime networking/logging APIs. Signature verification checks the complete sealed app and its nested code. These are bounded checks, not a guarantee that all security bugs have been eliminated.

Report suspected vulnerabilities privately through the repository's security reporting feature if available. Do not post credentials or private process diagnostics in public issues.
