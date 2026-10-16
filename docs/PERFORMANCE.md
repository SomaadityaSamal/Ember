# Performance and verification

Measured locally on an Apple M4 Mac, macOS 27, using release arm64 builds. These are short observations on a working machine with other apps active, not battery-life or energy measurements.

## CPU and memory

Each row uses six five-second `top` intervals after discarding its initial sample. **100% CPU means one logical core**, as in Activity Monitor. Memory is the final `top` memory value for the menu bar app; the optional root helper and fan client are separate processes.

### Ember 0.2.2: less work between readings

Process grouping now updates member arrays in place, reuses parsed app names and paths, and retains metadata only for paths in the current sample. Fresh executable paths and parent relationships are still read each time. Regression tests cover exec without PID/start-time changes, reparenting, and exact totals for a 512-helper group.

Optimized standalone Swift builds of the same synthetic fixture measured these median process CPU times over three runs:

| Fixture | 0.2.1 | 0.2.2 |
| --- | ---: | ---: |
| 1,000 processes, 100 samples/run | 2.247 ms/sample | 0.247 ms/sample |
| 2,000 processes, 30 samples/run | 7.540 ms/sample | 0.487 ms/sample |

Both fixtures put 75% of processes in one app and leave the rest as standalone workers to stress aggregation. They validate member counts and CPU totals on every sample. These are synthetic grouping measurements, not whole-app CPU reductions or energy measurements. Reproduce them with:

```sh
git fetch --tags
./scripts/benchmark-grouping.sh v0.2.1
./scripts/benchmark-grouping.sh
```

The expanded activity view uses lazy rows, selects only the requested five or 100 matches, and caches 27-point icons at the display's pixel scale. NSCache has 128-item/2 MiB eviction budgets; icons refresh on access after five minutes without a separate timer. App metadata and icons remain in memory only.

No client heartbeat timer runs in Auto or while threshold mode awaits a hot sample. When maximum control is active, a ten-second timer (one-second coalescing tolerance) renews the helper lease, including during UI tracking. Sensor polls still evaluate changes immediately; they no longer send duplicate renewals. The helper watchdog and 45-second expiry are unchanged.

The final installed build, with animation on, 15-second polling, the dashboard closed and fan control connected in Auto, averaged **0.27% of one core** (peak 0.80%) and **55 MB** across six five-second intervals after initial sampling. Other apps were active. This configuration differs from the older five-second observations below, so it is not a controlled before/after comparison.

On the target M4, Max remained confirmed after 50 seconds, beyond the helper's 45-second lease, proving that the demand-driven heartbeat renewed it. Target was 6,550 RPM and actual speed was about 6,547 RPM. Pausing then returned firmware mode to Auto and cleared the diagnostic flag. App/PID search, both activity filters, lazy scrolling, expanded details and thumbnail clarity were checked in the installed app.

### Ember 0.2.1: continuous animation

| Dashboard | Animation | Polling | Mean CPU | Peak CPU | App memory |
| --- | --- | --- | ---: | ---: | ---: |
| Open, fan spinning | On | 5 seconds | 0.62% | 0.70% | 67 MB |
| Closed | On | 5 seconds | 0.75% | 0.80% | 61 MB |

The orbit previously advanced twice per second, the fan four times per second, and the menu indicator used a redraw timer. Version 0.2.1 replaces those steps with cached layers animated continuously by Core Animation. Sensor polls do not restart the rotation. Closing the dashboard or disabling animation removes its animations, and Reduce Motion is honored. These numbers measure the app process; work performed by the system compositor and GPU is not attributed here, so they do not establish total energy savings.

### Ember 0.2.0: earlier animation baseline

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

- Thirteen Swift tests cover temperature classification, selected sensor sources, CPU timing and attribution, exec/reparenting, large helper groups, sustained activity, PID reuse, safe signaling, 5/15/30-second polling math, fan policies and unprivileged hardware rejection.
- A deterministic SMC simulator covers delayed firmware transitions in both directions, failed unlock/target writes, ownership conflicts, invalid values, maximum readback, and retryable restoration. It never touches hardware.
- On the target M4, Max selected a 6,550 RPM firmware target and actual fan speed reached approximately 6,553 RPM. Threshold changes to 45°C triggered Max; changing to 100°C returned to Auto. The threshold was restored to 80°C. These tests did not deliberately heat the laptop.
- Keeping a client connected without sending heartbeats caused the 45-second helper lease to expire and restore Auto. Firmware mode and diagnostic-flag readings confirmed restoration after 47 seconds. Normal app exit/crash also released control.
- The installed app displayed process activity on the 30-second cycle; switching through 15 and 5 seconds in Settings applied successfully without a crash.
- The native bridge passed Clang's static analyzer. Source and sealed app scans found no credential patterns or local home paths; nested signatures and the exact client identity pin passed verification.

Fan behavior on other Mac models is not verified. SMC control remains experimental. See [security boundaries and limits](../SECURITY.md).
