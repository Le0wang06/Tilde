# Tilde

Tilde is a native, local-first macOS command center for system health and AI coding agents.

This repository currently contains **Phase 0 only**: an intentionally plain SwiftUI diagnostic application used to verify macOS metrics and Codex App Server integration before product UI work begins.

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

No prompts, source code, terminal output, auth tokens, or account email are stored or printed.

See [Phase 0 Feasibility](Docs/Phase-0-Feasibility.md) for tested results and remaining limitations.
