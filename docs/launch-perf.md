# Launch And Install Performance Notes

Measured on April 11, 2026 from the local `blitz-macos` workspace.

Method:
- Warm-path timings used the current local `~/.blitz` installs.
- Cold-path timings downloaded the same artifacts used by the installer into `/tmp` and timed the real commands.
- Auto-update timings refer to the `.app.zip` path.

## Findings

### Legacy preinstall gating

- `preinstall` wall time in the measured environment: `23.48s`
- Almost all of that time came from the simulator runtime branch in `scripts/pkg-scripts/preinstall`:
  - `TIMING: simulator check took 23s`
- Fast-path command timings were negligible:
  - `xcode-select -p && xcodebuild -version`: `0.04s`
  - `xcrun clang` license probe: `0.01s`
  - `xcrun simctl list runtimes`: `0.08s`
  - `df -k /`: `0.00s`

Interpretation:
- Removing installer-time Xcode/simulator gating buys about `23.5s` in a broken or slow simulator-runtime environment.
- On a healthy machine where the runtime already exists, the steady-state savings are only about `0.1s` to `0.2s`.
- The stale disk-space threshold does not save runtime; it only changes whether install is blocked.

### Remaining postinstall and launch-time costs

- Node runtime bootstrap in `postinstall`:
  - Warm path: `0.07s`
  - Cold path: `44.33s`
- Python + `idb` bootstrap in `postinstall`:
  - Warm path: `0.69s`
  - Cold path: `43.57s`
- Launch-time `updateIphoneMCP()` npm refresh:
  - Cold path: `38.64s`
  - Warm path: `3.24s`

Interpretation:
- First install savings from removing the remaining `postinstall` bootstraps are about `87.9s` total:
  - `44.33s` Node
  - `43.57s` Python + `idb`
- Normal auto-update savings are small in the steady state:
  - Python + `idb` already skip during auto-update
  - Node warm check is about `0.07s`
- Launch-time `updateIphoneMCP()` was a recurring background tax of about `3.24s` per launch even on the warm path.

## Decisions Applied

- `.app.zip` auto-updates no longer run `preinstall`.
- Launch-time `updateIphoneMCP()` should not run on every launch.
- `iphone-mcp` installation should happen in `postinstall`, with runtime config preferring the installed binary and falling back to `npx` only if needed.
