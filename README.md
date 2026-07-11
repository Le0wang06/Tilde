# Tilde

Tilde is a native, local-first macOS command center for system health and AI coding agents.

This repository contains the completed **Phase 0** diagnostic application plus a minimal native menu-bar shell requested for local use. The menu-bar panel shares diagnostic state with the main window; broader Phase 1 application work has not started.

## Requirements

- macOS 14 or later
- Swift 6.1 or later
- Full Xcode for normal app development, XCTest, XCUITest, signing, and distribution
- Codex CLI is optional; system diagnostics still work without it

The current machine has Apple Command Line Tools but not full Xcode. SwiftPM builds work, while XCTest/XCUITest remain blocked until Xcode is installed and selected.

## Run

```sh
swift build
swift run TildeDiagnostics
```

Run the non-GUI feasibility report:

```sh
swift run tilde-probe
```

Run calculation and state tests:

```sh
./Scripts/test.sh
```

## Phase 0 scope

- CPU usage from Mach host counters
- Memory and swap from Mach and `sysctl`
- Memory pressure from the current macOS memorystatus pressure level
- Storage capacity from URL resource values
- Network rates from interface byte deltas
- Local IPv4 interface detection
- Battery and power source from IOKit power-source APIs
- Thermal state from `ProcessInfo`
- Explicit unavailable values for CPU temperature, GPU utilization, and fan speed
- Codex executable/version detection
- Codex App Server initialization, account, rate-limit, token-usage, and thread-list probes
- Native `MenuBarExtra` with health summary, refresh, open-window, and quit actions
- Menu bar title shows a tilde mark with remaining allowance and tokens used today (e.g. `~ 67% · 12K`) as an AppKit status item at the top of the screen
- Control Center–style menu panel with CPU/RAM/Disk/Network/Codex cards and Fan Boost (real SMC fan control via `tilde-fan`, green spinning fan + wind while on)

## Live updates

Tilde publishes local snapshots through a shared `AsyncStream` with newest-value buffering. The main window and menu-bar panel subscribe to the same sampling pipeline, so opening both does not duplicate system or Codex work.

Sampling adapts to visibility:

| Metric | Tilde visible | Background |
| --- | ---: | ---: |
| CPU and network | 1 second | 5 seconds |
| Memory and thermal state | 2 seconds | 10 seconds |
| Battery | 15 seconds | 60 seconds |
| Storage | 60 seconds | 5 minutes |
| Codex usage | 60 seconds | 2 minutes |

Manual refresh forces all metrics. Live samples stay in memory and are not written to disk.

## Native interface

The full window and menu-bar panel use the same restrained native visual system:

- Swift Charts backed by real bounded in-memory samples
- Compact metric tiles and axis-free live graphs
- Thin semantic capacity bars rather than oversized dashboard cards
- Memory color driven primarily by macOS memory pressure, not merely occupied RAM
- System materials, SF Symbols, native typography, and light/dark appearance support
- Green, orange, and red reserved for healthy, elevated, and critical states

No prompts, source code, terminal output, auth tokens, or account email are stored or printed.

See [Phase 0 Feasibility](Docs/Phase-0-Feasibility.md) for tested results and remaining limitations.
