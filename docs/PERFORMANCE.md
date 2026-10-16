# Performance and verification

Measured locally on an Apple M4 Mac, macOS 27, using the release arm64 build of Ember 0.2.0. These are short observations on a working machine with other apps active, not battery-life or energy measurements.

## CPU and memory

Each row uses six five-second `top` intervals after discarding its initial sample. **100% CPU means one logical core**, as in Activity Monitor. Memory is the final `top` memory value for the menu bar app; the optional root helper and fan client are separate processes.

| Dashboard | Animation | Polling | Mean CPU | Peak CPU | App memory |
| --- | --- | --- | ---: | ---: | ---: |
| Closed | On | 5 seconds | 3.47% | 3.90% | 63 MB |
| Open, fan spinning | On | 5 seconds | 17.58% | 18.80% | 68 MB |
| Closed, fresh session | Off | 30 seconds | 0.08% | 0.50% | 23 MB |
| Closed, helper connected in Auto | Off | 5 seconds | 1.03% | 1.30% | 60 MB |

Animation has a noticeable cost, especially with the dashboard open. Longer polling reduces process and sensor sampling work; disabling animation removes periodic visual updates. Reduce Motion also disables the animations. Close the dashboard when finished inspecting it. The helper's observed resident memory was about 7.5 MiB; its one-second watchdog and the client's ten-second heartbeat add work separately from the app values above.

Repeat a measurement with the app PID:

```sh
python3 scripts/measure-overhead.py APP_PID --samples 7 --seconds 5
```

Set the intended polling/animation preferences first. For a closed-panel sample, press Escape and do not reopen or query the app through UI automation during measurement. UI accessibility inspection and interaction add work and are excluded from these sampling windows. No process names, private diagnostics, or screenshots are included in release assets.

Numbers vary with process count, thermal state, hardware, panel content and OS. The 30-second case was a fresh session, while the other cases had exercised the dashboard, so memory differences cannot be attributed solely to animation. A short build/test run overlapped part of the open-panel observation; the table is not a controlled comparison. No battery drain percentage or measured wattage is claimed. Manual Max also increases the fan's own power use.

## Verified behavior

- Eleven Swift tests cover temperature classification, selected sensor sources, CPU timing and attribution, sustained activity, PID reuse, safe signaling, 5/15/30-second polling math, fan policies and unprivileged hardware rejection.
- A deterministic SMC simulator covers delayed firmware transitions in both directions, failed unlock/target writes, ownership conflicts, invalid values, maximum readback, and retryable restoration. It never touches hardware.
- On the target M4, Max selected a 6,550 RPM firmware target and actual fan speed reached approximately 6,553 RPM. Threshold changes to 45°C triggered Max; changing to 100°C returned to Auto. The threshold was restored to 80°C. These tests did not deliberately heat the laptop.
- Keeping a client connected without sending heartbeats caused the 45-second helper lease to expire and restore Auto. Firmware mode and diagnostic-flag readings confirmed restoration after 47 seconds. Normal app exit/crash also released control.
- The installed app displayed process activity on the 30-second cycle; switching through 15 and 5 seconds in Settings applied successfully without a crash.
- The native bridge passed Clang's static analyzer. Source and sealed app scans found no credential patterns or local home paths; nested signatures and the exact client identity pin passed verification.

Fan behavior on other Mac models is not verified. SMC control remains experimental. See [security boundaries and limits](../SECURITY.md).
