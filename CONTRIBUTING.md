# Contributing to Tilde

Tilde is a Swift 6.1 macOS menu-bar app that shows daily AI spend, a decision queue for agent work, exact local verification receipts, and machine health. This guide covers getting a build running, where code lives, the privacy rule every change must respect, and how pull requests flow.

## Prerequisites

- macOS 14 or later on Apple Silicon
- Swift 6.1 or later (`swift --version`)
- Xcode is optional. SwiftPM builds and `./Scripts/test.sh` work with Command Line Tools alone; the script adds the CLT framework search paths automatically. Xcode is needed only for signing and distribution.
- No external package dependencies; everything resolves from the system SDK.

## Build, test, run

```sh
git clone https://github.com/Le0wang06/Tilde.git
cd Tilde

swift build                                  # all products, debug
swift build -c release --product TildeDiagnostics
./Scripts/test.sh                            # swift-testing suite in Tests/TildeCoreTests

./Scripts/run-app.sh                         # build, wrap in .build/Tilde.app, open it
./Scripts/install-and-start.sh               # install ~/Applications/Tilde.app and a login LaunchAgent
./Scripts/uninstall.sh [--purge]             # remove the LaunchAgent and app (--purge also clears Application Support/Tilde)

swift run tilde-probe                        # CLI feasibility and diagnostics report
swift run tilde-fan                          # SMC fan control CLI (asks for admin once per login)
./Scripts/capture-readme-assets.sh           # regenerate README captures (needs Screen Recording permission)
```

`run-app.sh` accepts extra `swift build` flags, so `./Scripts/run-app.sh -c release` runs a release build.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/TildeCore` | Library with all reusable logic: monitoring (CPU, memory, thermal, storage, network, battery, fan/SMC), AI probes (Herdr, Codex, Cursor, spend), verification profiles and receipts, decision queue, session diary, deep-link parsing. No AppKit or SwiftUI. |
| `Sources/TildeDiagnosticsApp` | The menu-bar app: status item, panel views, banners, notification wiring. Thin over `TildeCore`. |
| `Sources/TildeProbe` | `tilde-probe` CLI. Prints what `TildeCore` can measure on this machine. |
| `Sources/TildeFanCLI` | `tilde-fan` CLI for SMC fan control. |
| `Tests/TildeCoreTests` | swift-testing suites for `TildeCore`. |
| `Scripts/` | Build, run, install, uninstall, test, and capture helpers. |
| `Docs/` | Feasibility study, control-plane notes, usefulness study, README assets. |

Rule of thumb from `AGENTS.md`: if it parses, computes, or persists, it belongs in `TildeCore` with a test. If it draws or wires up macOS, it belongs in `TildeDiagnosticsApp`.

## The local-first privacy rule

Tilde never persists prompts, terminal output, source code, diffs, authentication tokens, or account email. This is not a preference; it is the product contract stated in the README and enforced in review.

What Tilde may keep, all under `~/Library/Application Support/Tilde`:

- spend counters and cost estimates
- verification receipts: check IDs, command hashes, outcomes, timestamps, change fingerprints
- decision-queue entries: repository paths, worktree IDs, reasons
- session diary summaries (counts and short event labels)
- recovery hints (project path, branch)

Reads that are allowed but must stay in memory: the Cursor access token from `state.vscdb` is used for one HTTPS request and discarded; Codex app-server output is parsed for token counts only; Herdr output is reduced to agent state.

If a change writes anything new to disk, the pull request must list it under "Privacy impact".

## Branch and pull request workflow

1. Branch from `main` with a focused name: `feature/<topic>`, `fix/<topic>`, `research/<topic>`.
2. Keep the branch to one change. Split unrelated work.
3. Before pushing, run `swift build` and `./Scripts/test.sh`. If the panel changed, open it in both light and dark appearance.
4. Push and open a pull request against `main`. The PR template asks for summary, user-visible behavior, privacy impact, verification performed, and known limitations. Fill in all five.
5. Codex-authored commits append `Co-authored-by: Codex <codex@openai.com>`.
6. After a PR merges, small follow-ups (README, docs, assets) go straight to `main` rather than a second PR, per `AGENTS.md`.

CI runs on every push to `main` and every pull request: release build of `TildeDiagnostics`, debug build of `tilde-probe`, and `./Scripts/test.sh` on `macos-15`.

## Adding a verification profile

Exact verification runs the checks a repository declares in `.tilde/verify.json` and stores a receipt keyed to the change fingerprint and the profile hash. To add one to a repository:

1. Create `.tilde/verify.json` at the repository root. It must be a regular file, not a symlink.
2. Use this shape (this repository's own profile):

   ```json
   {
     "version": 1,
     "base": "origin/main",
     "checks": [
       { "id": "tests", "name": "Tests", "command": "./Scripts/test.sh", "required": true, "timeoutSeconds": 900 },
       { "id": "build", "name": "Build", "command": "swift build", "required": true, "timeoutSeconds": 600 }
     ]
   }
   ```

3. Constraints enforced by `VerificationProfileLoader`:
   - `version` must be `1`.
   - At least one check, and at least one with `required: true` (`required` defaults to `true`).
   - `id` is unique and uses only letters, digits, `.`, `_`, `-`.
   - `name` and `command` are non-empty.
   - `timeoutSeconds` is between 1 and 3600 (default 600).
   - `base` is optional and names the ref the change fingerprint is computed against.
4. Open the Tilde panel for that repository. Every command is shown verbatim, and nothing runs until you click Trust & Run for that repository and profile hash. Editing the profile changes the hash and requires re-trusting.
5. Receipts go stale when the change fingerprint moves (new commits or a changed working tree), so re-run after each change you want covered.

If you change the profile format itself, bump `version`, update the loader validation, add a test in `Tests/TildeCoreTests/VerificationReceiptTests.swift`, and note the compatibility impact in the PR.

## Reporting problems

Use the bug and feature issue forms. Never paste prompts, diffs, or command output into an issue. Security reports go through `SECURITY.md`.
