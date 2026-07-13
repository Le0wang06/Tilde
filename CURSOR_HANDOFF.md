# Cursor handoff: Tilde product direction and next implementation

Last updated: July 13, 2026

This is the durable handoff for continuing Tilde in Cursor. Read this file completely before
changing code. Then read `AGENTS.md`, `README.md`, and the files linked below.

## Immediate objective

The next core product increment is the **change-centered decision queue**.

Tilde should stop treating an agent process as the durable unit of work. The durable unit is an
agent-produced Git change: repository, worktree, base, branch, exact fingerprint, risks, matching
verification evidence, and the next human decision.

The target question is:

> Which change needs my judgment next, and what fresh evidence applies to it?

Do not start by adding another provider, quota visualization, transcript view, agent launcher, or
generic dashboard. Build the decision queue described in this handoff first.

## Repository state at handoff

- Workspace: `/Users/lw/Tilde`
- Current local branch: `feature/daily-ai-spend-menubar`
- Current local commit when this handoff was written: `1447faf`
- Current fetched `origin/main`: `4c56091` (merge of PR #21)
- Open roadmap PR: [#18 — evidence-backed product direction](https://github.com/Le0wang06/Tilde/pull/18)
- PR #19 merged: truthful trust facts and Codex quota windows
- PR #20 merged: exact local verification receipts
- PR #21 merged: daily AI price in the menu bar

Important: commit `1447faf` updated the README after PR #21 had already merged. It exists on
`feature/daily-ai-spend-menubar` but was not contained in `origin/main` at the time of this handoff.
Do not delete the branch or assume every post-merge commit reached `main` without checking:

```sh
git fetch origin --prune
git log --oneline origin/main..origin/feature/daily-ai-spend-menubar
git branch -a --contains 1447faf
```

The detailed study is currently on `research/tilde-usefulness-study`, not the checked-out branch.
Read it without switching branches:

```sh
git show research/tilde-usefulness-study:Docs/Tilde-Usefulness-Study.md
git show research/tilde-usefulness-study:Docs/AI-Control-Plane.md
```

Before starting implementation, reconcile the current branch with `origin/main`, preserve any
post-merge documentation commits intentionally, and create a focused feature branch as required by
`AGENTS.md`.

## Product decision from the research

Tilde should be a **local decision queue and verification ledger for agent-produced changes**. It
should sit above Codex, Claude Code, Cursor, Herdr, Git worktrees, and CI without trying to own those
runtimes.

The research found that code generation is no longer the main constraint. The recurring expensive
work is:

1. deciding which completed or blocked change deserves attention;
2. reconstructing branch, worktree, task, and verification context;
3. determining whether tests or CI apply to the exact current change;
4. allocating extra review to risky or out-of-scope changes;
5. finding parallel-work conflicts before merge;
6. returning to the exact work surface after interruption.

Tilde's differentiated combination is:

- ambient macOS surface;
- cross-provider inputs;
- change-centered state;
- deterministic, freshness-bound evidence;
- local-first privacy.

The one-sentence promise is:

> Tilde tells you which agent-produced change needs you next and whether its evidence is still valid.

## Product boundaries

Do not turn Tilde into:

- an agent launcher or orchestration kanban;
- a terminal or transcript viewer;
- a full diff editor;
- a prompt, token, commit, or lines-of-code productivity score;
- an AI confidence, risk percentage, or opaque safety score;
- another permanently expanded machine-monitor dashboard.

Provider apps should run agents. Editors and Git clients should show and edit source. Tilde should
rank decisions, present exact evidence, and deep-link to the proper surface.

## What has shipped

### Agent attention foundation

- Live Herdr agent inventory with repository and branch resolution.
- Idle agents remain visible in the panel.
- Blocked and completed/ready agents are ordered before working or idle agents.
- Working agents do not consume menu-bar width.
- Transition-only notifications avoid initial-discovery notification spam.
- Clicking an agent returns the user to its Herdr terminal.
- Recovery capsules store metadata and a next-action hint without storing source or transcripts.
- Session-diary events record agent attention transitions as metadata.

Core files:

- `Sources/TildeCore/AI/Herdr/HerdrAgentProvider.swift`
- `Sources/TildeCore/AI/Herdr/AgentAttention.swift`
- `Sources/TildeCore/AI/Herdr/AgentAttentionNotifier.swift`
- `Sources/TildeCore/Diary/RecoveryCapsuleStore.swift`
- `Sources/TildeCore/Diary/SessionDiaryStore.swift`
- `Tests/TildeCoreTests/AgentAttentionTests.swift`
- `Tests/TildeCoreTests/RecoveryCapsuleTests.swift`

### Truthful trust facts

PR #19 corrected known false-green behavior:

- committed and uncommitted branch changes are compared with a resolved base;
- CI evidence is matched to the current commit instead of borrowing the newest unrelated run;
- build observation is treated as context, not proof for an exact Git state;
- clean, risk, and verified are separate facts;
- Codex quota windows are classified by duration rather than unreliable primary/secondary order.

Core files:

- `Sources/TildeCore/Verification/TrustPacket.swift`
- `Sources/TildeCore/Monitoring/ProjectContextMonitor.swift`
- `Sources/TildeCore/Models/CodexDiagnosticSnapshot.swift`
- `Tests/TildeCoreTests/TrustPacketTests.swift`
- `Tests/TildeCoreTests/ProjectContextMonitorTests.swift`
- `Tests/TildeCoreTests/MetricCalculationTests.swift`

### Exact local verification receipts

PR #20 added explicit repository-configured verification:

- `.tilde/verify.json` declares reviewable commands and the base ref;
- a new or changed profile must be explicitly trusted before execution;
- commands run with cancellation and timeout support;
- the entire command process group is terminated on cancellation or timeout;
- command output is ephemeral and is not persisted;
- receipt metadata is bound to repository/worktree/profile and a complete Git fingerprint;
- receipts become stale immediately when any material fingerprint component changes;
- results can be rerun or cleared and hidden;
- clearing removes the stored result, so the next result requires a fresh run.

The fingerprint covers the base tip, merge base, `HEAD`, staged changes, unstaged changes, untracked
path/mode/size/content, dirty submodules, and verification-profile hash. Tilde requires two identical
complete samples before accepting a fingerprint.

Core files:

- `.tilde/verify.json`
- `Sources/TildeCore/Verification/ChangeFingerprintProvider.swift`
- `Sources/TildeCore/Verification/VerificationModels.swift`
- `Sources/TildeCore/Verification/VerificationProfileLoader.swift`
- `Sources/TildeCore/Verification/VerificationCommandRunner.swift`
- `Sources/TildeCore/Verification/VerificationReceiptStore.swift`
- `Sources/TildeCore/Verification/VerificationService.swift`
- `Tests/TildeCoreTests/VerificationReceiptTests.swift`

Phase 1 is substantially implemented, but its under-five-second comprehension gate and 20-change
dogfood gate have not been measured rigorously. Treat implementation completion and product
validation as separate facts.

### Daily AI price

PR #21 replaced persistent quota percentages with a compact price. The menu-bar title now contains
only the price, for example `≈$58.35`:

- no branch name;
- no active-agent name or count;
- no build, verification, focus, or slowdown marker;
- no `today` suffix;
- no trailing `+` marker.

The expanded panel retains provider breakdown, quota windows, and estimate context.

Codex details:

- `account/usage/read` supplies the reported daily activity-token bucket;
- local Codex JSONL files are scanned only for model-context and token-count events;
- prompt and response events are ignored;
- input, cached-input, and output tokens are priced separately through the versioned official Codex
  credit rate card;
- the reported activity bucket is a cross-check and is never priced as an undifferentiated total;
- the scanner caches file offsets and processes appended events incrementally;
- no Codex token breakdown is persisted;
- `≈` means credit-equivalent estimate, not necessarily a cash charge under a subscription.

`CodexCostEstimator.rateCardVersion` is `2026-07-13`, and its supported model rate table must be
updated deliberately when official rates change. Unsupported models remain unpriced rather than
guessed.

Cursor details:

- Cursor exposes a cumulative current-period monetary counter through an unofficial API;
- Tilde stores a local daily baseline and displays the observed delta;
- the first observation cannot recover usage from earlier in that day;
- the ledger persists monetary counters and timestamps only.

Core files:

- `Sources/TildeCore/AI/Codex/CodexAppServerProbe.swift`
- `Sources/TildeCore/AI/Codex/CodexCostEstimator.swift`
- `Sources/TildeCore/AI/Cursor/CursorUsageProbe.swift`
- `Sources/TildeCore/AI/Spend/DailyAISpend.swift`
- `Sources/TildeDiagnosticsApp/MenuBarStatusItemController.swift`
- `Tests/TildeCoreTests/DailyAISpendTests.swift`

Do not describe the estimated value as an actual bill or guaranteed money charged.

## Architecture and contribution constraints

The package requires macOS 14+ and Swift 6.1+.

Products:

- `TildeDiagnostics`: AppKit/SwiftUI menu-bar app and diagnostics window;
- `TildeCore`: reusable monitoring, parsing, attention, verification, and persistence logic;
- `tilde-probe`: non-GUI feasibility/live-data probe;
- `tilde-fan`: privileged fan-control helper.

Architectural rule:

- reusable Git discovery, parsing, state reduction, ranking, and persistence belong in `TildeCore`;
- AppKit/SwiftUI presentation and user interaction wiring belong in `TildeDiagnosticsApp`;
- avoid adding more product logic directly to the already-large `DiagnosticViewModel` in
  `Sources/TildeDiagnosticsApp/TildeDiagnosticsApp.swift`.

Monitoring is local and adaptive. Sampling slows when the panel is closed, and each provider must
be able to fail independently without breaking system monitoring.

Read `AGENTS.md` before every implementation. The required workflow is:

1. create a focused branch;
2. implement the requested slice;
3. run `./Scripts/test.sh` and `swift build`;
4. commit all intended files;
5. use the configured Git author;
6. append `Co-authored-by: Codex <codex@openai.com>` only for Codex-authored changes;
7. push and open a PR against `main`;
8. document user behavior, privacy, verification, and limitations in the PR.

Do not overwrite unrelated user changes in a dirty worktree.

## Non-negotiable privacy model

Never persist:

- prompts or chat transcripts;
- terminal or verification command output;
- source code, raw diffs, or source snippets;
- account email;
- authentication tokens or credentials.

Allowed persisted data is narrowly scoped metadata such as:

- repository/worktree identifiers and hashes;
- branch and Git object IDs;
- changed-path categories and counts;
- profile/fingerprint hashes;
- check names, timestamps, durations, outcomes, and exit statuses;
- CI run IDs, URLs, and matching head SHA;
- provider/session references that do not contain conversation content;
- attention state and next-action hints;
- monetary counters needed for the local Cursor baseline.

Source and raw diffs may be read and hashed in memory when required, but must not be written to
Tilde's stores. UI display of source must remain ephemeral and opt-in.

## Next implementation: Phase 2 decision queue

### Goal

The normal popover should answer the next-decision question in seconds. It should show one card per
active change and rank the few changes requiring human judgment above ongoing or idle activity.

### Recommended implementation order

#### 1. Introduce a change-centered model

Add reusable models in `TildeCore`, likely under a new `ChangeQueue` or `Changes` directory. Names
can change, but the responsibilities should remain explicit:

- `ChangeSetID`: stable repository + worktree identity;
- `ChangeSet`: repository, worktree, base, merge base, branch, head, fingerprint, associated
  provider/session references, PR/CI match, verification state, and deterministic risks;
- `DecisionReason`: blocked question, verification failed, verification missing, stale evidence,
  ready for review, conflict, or other factual reason;
- `DecisionQueueItem`: a `ChangeSet`, reason, deterministic priority, and available actions;
- `DecisionQueueSnapshot`: ranked items plus collapsed working/idle counts and discovery notes.

Do not store raw source, diffs, prompt text, or terminal output in these models.

#### 2. Discover all active worktrees

Build a discovery service that:

- uses `git worktree list --porcelain` for each canonical repository;
- resolves repository identity, worktree path, branch/detached state, base, merge base, and head;
- associates Herdr agents by canonicalized working-directory/repository identity;
- reuses `ChangeFingerprintProvider` and `VerificationService` per worktree;
- tolerates deleted, locked, detached, missing-upstream, and temporarily inaccessible worktrees;
- reports unavailable facts instead of inventing defaults;
- deduplicates multiple agents associated with the same change.

Discovery must be read-only. It must not checkout, merge, rebase, stage, clean, or mutate a
repository.

#### 3. Add deterministic queue ranking

Put ranking in a pure/testable reducer in `TildeCore`. A reasonable initial order is:

1. agent blocked or explicitly awaiting user input;
2. merge/conflict condition requiring a decision;
3. exact verification failed;
4. previously verified evidence became stale;
5. ready change with missing required verification;
6. exact verified change ready for human review;
7. working change;
8. idle/no-change worktree.

Tie-break with stable factual inputs such as severity, transition time, repository name, and
worktree path. Do not use an unexplained AI score.

Every surfaced reason must say what Tilde observed and what action the user can take.

#### 4. Replace the metric-first popover hierarchy

The normal popover should fit without scrolling in the ordinary case:

1. `Needs you`: up to three highest-priority change cards;
2. `Working`: a collapsed summary, expandable on demand;
3. footer warnings: quota reset or machine-health warnings only when relevant.

Move detailed CPU, RAM, fan, disk, network, usage history, diary, and settings into the full window
or a secondary panel. Do not delete working diagnostics; demote them from the primary decision flow.

The menu-bar title must remain price-only unless the user explicitly changes that requirement.

#### 5. Add actions without owning the workflow

Each decision card should expose only applicable actions:

- `Review change`: open the exact worktree in the configured editor/Git surface;
- `Run missing checks`: invoke the existing trusted `VerificationService` flow;
- `Open agent`: return to the associated Herdr/provider surface;
- `Open PR`: open the matching PR URL when exact repository/head association exists.

Never run repository commands automatically. A new or changed verification profile remains a trust
boundary and must be shown before execution.

#### 6. Add tests before UI polish

At minimum, cover:

- two worktrees in one repository become two change cards;
- two agents in one worktree become one change card with multiple associations;
- committed-only change against base remains visible;
- untracked-only change remains visible;
- detached HEAD and missing upstream are factual unavailable/partial states;
- failed verification outranks ready verified review;
- stale verification outranks ordinary working state;
- blocked state outranks all non-conflict ordinary work;
- one provider failure does not erase Git-discovered changes;
- discovery and conflict checks never mutate a repository;
- queue ordering is deterministic across repeated samples;
- no persisted queue record contains source, diff, prompt, output, email, or credential material.

### Phase 2 acceptance gate

- One card represents one change, not one process.
- All active worktrees are discoverable without repository mutation.
- Exact receipt freshness is shown per change.
- The top card leads to the correct next action in at least 90% of dogfood decisions.
- Normal popover use does not require scrolling.
- Background CPU remains below 1% during ordinary idle monitoring.
- Initial discovery produces no notification spam.
- A provider failure cannot break Git discovery or verification.

## Later roadmap

### Phase 3: deterministic risk and scope

- Expand sensitive path categories: auth, permissions, credentials, encryption, migrations,
  dependencies, CI/deployment/build scripts, entitlements, agent instructions, skills, hooks, MCP,
  and rules files.
- Allow an optional task scope with intended outcome, expected paths, and acceptance checks.
- Flag out-of-scope paths and changed instruction surfaces.
- Produce a factual review recipe rather than an AI summary.
- Copy a compact Markdown receipt for PR descriptions or handoff.
- Keep irrelevant warning rate below 10% in dogfooding.

### Phase 4: conflict radar

- Use `git worktree list --porcelain` and read-only `git merge-tree` simulation.
- Detect textual conflicts, same-file overlap, high-risk-area overlap, and base drift.
- Distinguish a proven textual conflict from a semantic-overlap advisory.
- Suggest a review/merge order, clearly labeled as a recommendation.
- Never mutate a checkout during detection.

### Phase 5: supported provider adapters

- Codex: App Server thread list/status events, cwd, Git metadata, and supported approvals.
- Claude Code: lifecycle/notification hooks and agent-team state, installed only with consent.
- Cursor: supported Background Agent API when explicitly configured; otherwise partial/unavailable.
- Herdr: retain the existing CLI adapter.
- Preserve signal provenance as `exact`, `inferred`, or `unavailable`.
- One adapter failure must not affect other adapters, Git discovery, verification, or monitoring.

Provider breadth is compatibility work, not Tilde's primary differentiation. Do it after the
change-centered loop proves useful.

## Product validation plan

Run a two-part, 20-change dogfood study rather than relying on feature completion.

For 10 baseline agent-produced changes, record locally:

- time from agent completion to opening the correct change;
- time reconstructing branch/worktree/task context;
- commands rerun manually to establish confidence;
- wrong-branch or stale-evidence incidents;
- correction loops after first review;
- conflicts discovered late;
- self-rated decision confidence from 1 to 5.

For 10 comparable Tilde decision-queue changes, record the same outcomes plus:

- decision cards shown and acted on;
- false or irrelevant cards;
- correct receipt invalidations;
- warnings accepted, dismissed, or repeatedly ignored;
- time from opening Tilde to taking the next action.

Success criteria:

- zero false `verified` states;
- at least 30% lower median review-setup/recovery time;
- at least 90% correct next-action cards;
- less than 10% irrelevant deterministic risk warnings;
- all intentionally seeded textual worktree conflicts detected before merge;
- background CPU below 1%;
- no forbidden persisted data;
- the user voluntarily opens Tilde for at least half of ready-to-review handoffs.

If these gates fail, improve the change model and decision cards before adding providers or more
dashboard features.

## Known limitations and cautions

- Herdr status is coarse and provider-thin. Treat `blocked`, `working`, `done`, and `idle` as Herdr
  observations, not universal truth.
- Codex cost is an estimate based on a versioned rate card and local token classes.
- Cursor cost starts from a local observation baseline and can miss earlier same-day usage.
- The detailed research PR remains open and may conflict with newer README/control-plane edits;
  reconcile it rather than blindly merging stale documentation.
- Full Xcode/XCUITest coverage is not established. Current conventional coverage uses Swift
  Testing, builds, live probes, and reviewed native captures.
- `DiagnosticViewModel` is large. Prefer new core services and small UI adapters over adding more
  stateful logic to it.
- System monitoring and fan control work, but they are supporting utilities rather than the primary
  product wedge.

## Build, test, run, and capture

```sh
swift build
./Scripts/test.sh
swift run tilde-probe
./Scripts/run-app.sh
./Scripts/capture-readme-assets.sh
```

At this handoff, the conventional suite contains 48 tests. Do not merely preserve the count; add
focused tests for new behavior. Always run `git diff --check` before committing.

The README capture script terminates/relaunches the packaged diagnostics app while generating
assets. It can rewrite all three PNGs even when only the menu-bar image changed. Review binary asset
diffs and avoid committing unrelated recaptures.

For a live visual check after restart:

```sh
screencapture -x /private/tmp/tilde-live.png
```

Verify the running process with:

```sh
pgrep -fl TildeDiagnostics
```

## Definition of done for the next Cursor session

The next session is complete only when:

1. the current Git state and post-merge documentation commits are reconciled intentionally;
2. the detailed research handoff has been read;
3. a focused branch exists for the decision-queue slice;
4. worktree discovery and change-centered models live in `TildeCore`;
5. deterministic queue ranking has fixture coverage;
6. the popover shows change cards rather than a process/metric-first hierarchy;
7. actions open the exact change/agent/PR or invoke trusted checks;
8. privacy constraints are covered by code review and tests;
9. `./Scripts/test.sh`, `swift build`, and `git diff --check` pass;
10. the app is restarted and the native UI is visually reviewed;
11. intended files are committed and pushed under the contribution workflow;
12. the PR explains behavior, privacy, verification, and limitations.

When uncertain, prefer a truthful unavailable state over an inferred green state. Tilde's value is
not that it always has an answer; it is that the evidence it shows still applies to the exact
change the user is deciding about.
