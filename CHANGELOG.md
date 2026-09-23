# Changelog

All notable changes to Tilde are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Setup guidance in the panel when Herdr is not installed, no repository is detected, or the current repository has no `.tilde/verify.json`.
- Accessibility labels on panel cards, section headers, and actions.
- Light-mode README captures alongside the dark ones.
- GitHub Actions CI: release build of `TildeDiagnostics`, build of `tilde-probe`, and `./Scripts/test.sh` on `macos-15`.
- MIT license.
- `CONTRIBUTING.md`, `SECURITY.md`, issue forms, and a pull request template.
- `Scripts/uninstall.sh` to remove the LaunchAgent and app bundle, with `--purge` for Application Support data.
- `.editorconfig`.

### Changed

- System and Spend sections in the panel are collapsible.
- Card transitions in the panel are animated.

## [0.1.0] - 2026-07-19

First working slice of the AI control plane.

### Added

- Menu-bar title showing today's AI spend, with Codex daily cost estimated from token classes and Cursor usage read from the local plan.
- "Needs you" decision queue: change-centered cards for agent work awaiting a decision, ordered with blockers first and aware of git worktrees.
- Attention banners: native macOS notifications with sound when a Herdr agent needs input or finishes a turn, plus a manual smoke trigger.
- Exact verification receipts: `.tilde/verify.json` profiles, Trust & Run per repository and profile hash, receipts keyed to the change fingerprint, and clearing of stale results.
- Truthful trust packet and Codex windows that report only what can be measured.
- Fan Boost with real SMC control through the `tilde-fan` CLI.
- System HUD: CPU sparkline, memory pressure, storage, network, thermal, battery, and advanced sensors reported as unavailable when they are.
- Combined AI card cycling between Codex and Cursor budgets.
- Local session diary with a Today summary.
- `tilde://` deep links for common actions.
- Ship, Meet, and Battery focus presets.
- Active git project, branch, and CI status in the HUD.
- `tilde-probe` CLI feasibility report.
- Install script that builds `~/Applications/Tilde.app` and registers a login LaunchAgent.

[Unreleased]: https://github.com/Le0wang06/Tilde/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Le0wang06/Tilde/releases/tag/v0.1.0
