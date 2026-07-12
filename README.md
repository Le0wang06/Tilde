# Tilde

Tilde is a native, local-first macOS command center for system health and AI coding agents.

Its menu-bar control plane combines machine health with live Herdr agent attention,
deterministic change-verification evidence, and a private per-project recovery capsule.

This repository contains the completed **Phase 0** diagnostic foundation and the first
AI-control-plane vertical slice. The native menu-bar panel shares system, agent, project,
verification, and recovery state with the main window.

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

For `tilde://` deep links (open window, refresh, copy status, open Cursor, focus modes), package and launch as an app so Launch Services registers the URL scheme:

```sh
chmod +x Scripts/run-app.sh
./Scripts/run-app.sh
open 'tilde://refresh'
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
- Native AppKit status item with health summary, refresh, open-window, and quit actions
- Menu bar title shows Codex + Cursor remaining allowance (e.g. `~ Cx 67% · Cr 45%`)
- Herdr agent attention, transition notifications, and focus actions
- Deterministic Git/build/CI trust evidence and local recovery capsules
- Control Center–style menu panel with CPU/RAM/Disk/Network/Codex/Cursor cards and Fan Boost (real SMC fan control via `tilde-fan`, green spinning fan + `~` spray while on; admin password once per login via a background daemon)

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
| Cursor usage | 2 minutes | 5 minutes |
| Herdr agents | 2 seconds | 2 seconds |

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

## AI attention and verification

When a local Herdr server is available, Tilde polls its structured agent inventory and maps
each terminal to its actual Git repository and branch. The menu-bar panel shows agents that
need input or have work ready to review before agents that are merely working. Selecting an
agent focuses its Herdr terminal and activates the host terminal application.

Tilde posts transition-based notifications for new blockers and completed work. The first
inventory is treated as a baseline, so launching Tilde does not replay stale alerts.

For the active project, a deterministic trust packet summarizes changed-file and line counts,
build and CI evidence, upstream drift, and elevated-risk configuration paths. It does not
assign an opaque AI confidence score and does not persist source or diff content.

A recovery capsule stores only project metadata under Application Support: repository path,
branch, attention count, verification state, changed-file count, and the inferred next action.
This provides a compact resume point after switching projects without retaining prompts or
terminal transcripts.

See [Phase 0 Feasibility](Docs/Phase-0-Feasibility.md) for tested results and remaining limitations.
