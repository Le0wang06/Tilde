# Tilde

<p align="center">
  <img src="Docs/assets/tilde-hero.png" alt="Tilde — menu-bar command center" width="920" />
</p>

<p align="center">
  <strong>Native macOS menu-bar command center</strong><br/>
  Machine health · AI agent attention · Change verification · Local recovery
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square" />
  <img alt="Swift 6.1" src="https://img.shields.io/badge/Swift-6.1-F05138?style=flat-square&logo=swift&logoColor=white" />
  <img alt="Local-first" src="https://img.shields.io/badge/privacy-local--first-2ea44f?style=flat-square" />
  <img alt="SwiftPM" src="https://img.shields.io/badge/build-SwiftPM-555?style=flat-square" />
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#gallery">Gallery</a> ·
  <a href="#what-you-get">Features</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#docs">Docs</a>
</p>

---

Tilde lives in your menu bar and answers four questions without stealing focus:

| | Question | What Tilde shows |
| ---: | --- | --- |
| **1** | What needs me? | Blocked / ready Herdr agents, ordered by attention |
| **2** | What changed? | Branch, dirty state, ahead/behind, project context |
| **3** | Is it safe? | Deterministic Git · build · CI trust evidence |
| **4** | Where do I resume? | Private recovery capsule per project |

Editors edit. Herdr runs agents. **Tilde is the ambient layer between them.**

## Gallery

Live captures from the running app, with project/agent identity and account-usage values replaced by demo stubs:

<p align="center">
  <img src="Docs/assets/tilde-menubar.png" alt="Tilde status item in the macOS menu bar" width="920" />
</p>

<p align="center"><sub>Real menu-bar title — attention, Codex budget, and live signals</sub></p>

<p align="center">
  <img src="Docs/assets/tilde-panel-dark.png" alt="Tilde control panel from the running app" width="360" />
</p>

<p align="center"><sub>Actual menu-bar panel — agents, CPU/RAM/Fan, AI budget, trust, focus</sub></p>

<p align="center">
  <img src="Docs/assets/tilde-hero.png" alt="Tilde README hero with live panel" width="920" />
</p>

Re-capture anytime with:

```sh
./Scripts/capture-readme-assets.sh
```

## What you get

| Area | In the menu bar / panel |
| --- | --- |
| **System HUD** | CPU sparkline, RAM pressure, disk, network, thermal slowdown alerts |
| **Fan Boost** | Real SMC fan control via `tilde-fan` (admin password once per login) |
| **AI budget** | Codex ⇄ Cursor remaining % in one tap-to-cycle card |
| **Agent attention** | Herdr inventory, blockers first, one-click focus back to the terminal |
| **Exact verification** | Explicit repository checks bound to the full Git fingerprint; stale immediately after a change |
| **Trust packet** | Deterministic Git / exact receipts / CI evidence — no opaque “AI confidence” |
| **Recovery** | Per-project capsule (metadata only) so you can resume cleanly |
| **Focus modes** | Ship · Meet · Battery presets |
| **Today diary** | Local JSONL of builds, focus, slowdowns, agent events |

## Quick start

**Needs:** macOS 14+ · Swift 6.1+  
Xcode is optional for SwiftPM runs; required for XCTest, signing, and distribution.

```sh
git clone https://github.com/Le0wang06/Tilde.git
cd Tilde
swift build
./Scripts/run-app.sh     # wraps .app + registers tilde://
```

| Command | What it does |
| --- | --- |
| `./Scripts/run-app.sh` | Build, package as `.app`, launch, register URL scheme |
| `swift run TildeDiagnostics` | Run without packaging |
| `swift run tilde-probe` | Non-GUI probe / feasibility report |
| `./Scripts/test.sh` | Calculation + state tests |

## Deep links

After `./Scripts/run-app.sh`:

| URL | Action |
| --- | --- |
| `tilde://open` | Open main window |
| `tilde://refresh` | Force refresh |
| `tilde://copy-status` | Copy HUD summary |
| `tilde://open-cursor` | Launch Cursor |
| `tilde://focus/ship` | Ship mode |
| `tilde://focus/meet` | Meet mode |
| `tilde://focus/battery` | Battery mode |

```sh
open 'tilde://refresh'
```

## How it fits together

```mermaid
flowchart TB
  MB["Menu bar · ~ title"]
  PN["Compact panel"]
  MB --> PN

  PN --> LIVE["LiveMonitoringService"]
  PN --> AG["HerdrAgentProvider"]
  PN --> TR["Trust / verification"]
  PN --> FAN["FanBoost + tilde-fan"]
  PN --> DY["Session diary"]

  LIVE --> CX["Codex"]
  LIVE --> CR["Cursor"]
  AG --> HR["Herdr"]
  TR --> GT["Git / gh"]
  FAN --> SMC["SMC"]
```

Sampling slows when the panel is closed. Manual refresh forces everything. Live samples stay **in memory** — not on disk.

<details>
<summary>Sampling intervals</summary>

| Metric | Visible | Background |
| --- | ---: | ---: |
| CPU / network | 1s | 5s |
| Memory / thermal | 2s | 10s |
| Battery | 15s | 60s |
| Storage | 60s | 5m |
| Codex | 60s | 2m |
| Cursor | 2m | 5m |
| Herdr agents | 2s | 2s |

</details>

## Privacy

Tilde is **local-first**. It does **not** store:

- prompts or chat transcripts  
- source code or diffs  
- terminal output  
- auth tokens or account email  

Recovery capsules keep only path, branch, attention counts, verification state, and a next-action hint under Application Support.
Verification receipts keep only repository/worktree/profile/fingerprint hashes, Git object IDs, check
IDs and names, timestamps, durations, outcomes, and exit statuses. Command output remains ephemeral
and is never written to the receipt store.

## Exact verification profiles

Tilde never guesses or automatically runs repository commands. A repository can declare a reviewable
`.tilde/verify.json`; Tilde shows every command and requires an explicit **Trust & Run** click for that
repository and exact profile hash. Changing the profile requires trust again. After a run, **Clear
Result** deletes that worktree's stored receipt and returns the card to its ready-to-run state.

```json
{
  "version": 1,
  "base": "origin/main",
  "checks": [
    {
      "id": "tests",
      "name": "Tests",
      "command": "./Scripts/test.sh",
      "required": true,
      "timeoutSeconds": 900
    }
  ]
}
```

A receipt becomes stale when the base tip, merge base, `HEAD`, staged diff, unstaged diff, untracked
path/mode/size/content, dirty submodule state, or profile changes. Tilde requires two identical complete
fingerprint samples before using one, scopes receipts to the current worktree, and terminates the full
verification process group on cancellation or timeout.

## Repo layout

| Product | Role |
| --- | --- |
| `TildeDiagnostics` | Menu-bar app + diagnostics window |
| `tilde-probe` | CLI feasibility report |
| `tilde-fan` | Privileged fan daemon / CLI |
| `TildeCore` | Shared monitoring, agents, trust, diary |

## Docs

- [AI Control Plane](Docs/AI-Control-Plane.md) — promise, shipped slice, next steps  
- [Phase 0 Feasibility](Docs/Phase-0-Feasibility.md) — measured results and limits  
- [Contribution workflow](AGENTS.md)

## Status

Phase 0 diagnostics are solid. The AI attention / verification slice is in active dogfooding. Release gates: idle CPU, no notification spam on launch, low false blocked/done rates — details in the control-plane doc.

---

<p align="center">
  <sub>Built for people who already live in the menu bar.</sub><br/>
  <strong>~</strong>
</p>
