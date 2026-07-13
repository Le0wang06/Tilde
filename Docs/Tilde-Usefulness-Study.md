# Making Tilde genuinely useful

Research and product direction, July 13, 2026

## Executive decision

Tilde should not become another coding-agent launcher, kanban board, transcript viewer, or generic
menu-bar monitor. Those categories are already crowded, including by the agent vendors themselves.

Tilde's best product is a **local decision queue and verification ledger for agent-produced
changes**. It should sit above Codex, Claude Code, Cursor, Herdr, and Git worktrees and answer one
high-value question:

> What is the next change that needs my judgment, and what fresh evidence do I have for it?

The change—not the agent process—should be the durable unit in Tilde. An agent can stop, restart,
or hand work to another provider; the branch, worktree, exact diff, risks, and verification evidence
remain.

This direction keeps Tilde's strongest qualities:

- local-first operation;
- provider independence;
- a calm, ambient macOS surface;
- deterministic evidence rather than another AI confidence score.

It also requires a candid correction: Tilde's current `Trust` label is not yet strong enough to be
called trust. It can miss committed changes, associate CI from the wrong branch, and treat observed
build activity as evidence without binding that result to an exact Git state. Correctness of this
model is the first release gate.

## Research question

What repeated, costly problem remains after an AI coding agent can already launch tasks, use
worktrees, notify the developer, show a diff, and open a pull request?

The answer across the strongest evidence is **human verification and coordination capacity**:

1. Agents generate changes faster than humans can understand and validate them.
2. Developers do not consistently trust the output, but verification itself is expensive.
3. Parallel work moves the bottleneck from generation to attention, review, and reconciliation.
4. The evidence needed to make a decision is scattered across terminals, Git, CI, and provider
   interfaces.
5. Returning to a change after an interruption requires reconstructing state and intent.

## Method and evidence quality

This study combined four evidence types:

1. **Broad surveys:** Stack Overflow, DORA, Sonar, and Microsoft/GitHub developer research.
2. **Measured studies:** METR's randomized developer-productivity work and recent large-scale
   studies of agent-authored pull requests and risk-aware review.
3. **Current product behavior:** official Codex, GitHub Copilot, Claude Code, and Cursor
   documentation, plus current adjacent products.
4. **Code and UI audit:** the current Tilde implementation, tests, README, and captured UI.

Important limitations:

- Vendor surveys can reflect the vendor's framing and customer population.
- Forum reports are useful for discovering workflows and failure modes, not estimating prevalence.
- The early-2025 METR randomized trial is a historical snapshot; METR's later experiment suggests
  improvement but has selection and measurement problems.
- Product pages describe intended capability, not independently verified reliability.
- This is not product-market-fit evidence. Tilde still needs measured dogfooding and interviews.

## What the evidence says

### 1. Verification is the bottleneck

The 2025 Stack Overflow survey reports that 46% of respondents distrust AI-tool accuracy while 33%
trust it. The most common frustration, reported by 66%, is output that is almost right; 45% report
that debugging AI-generated code takes more time. The same survey found that 69% of agent users
perceived a personal productivity gain, but only 17% perceived improved team collaboration. This is
the gap between faster individual generation and a better end-to-end system.
([Stack Overflow AI survey](https://survey.stackoverflow.co/2025/ai))

Sonar's 2026 survey of more than 1,100 professional developers reports that 96% do not fully trust
AI-generated code, only 48% always verify it before committing, and 38% say reviewing AI code takes
more effort than reviewing a colleague's code. Treat the exact numbers as vendor research, but the
direction agrees with the much larger Stack Overflow survey.
([Sonar State of Code](https://www.sonarsource.com/blog/state-of-code-developer-survey-report-the-current-reality-of-ai-coding/))

DORA characterizes AI as an amplifier of the delivery system around it. Its research specifically
recommends fast, high-quality feedback loops because increased generation can produce larger review
batches and more instability when testing and review do not keep up.
([DORA 2025 report](https://dora.dev/research/2025/dora-report/),
[DORA impact report](https://dora.dev/ai/gen-ai-report/report/))

**Product implication:** Tilde should shorten and strengthen verification, not generate more code or
more prose about code.

### 2. Productivity claims are incomplete without end-to-end measurement

METR's early-2025 randomized trial covered 16 experienced open-source developers and 246 real tasks.
Developers using then-current AI tools took 19% longer. A later experiment using newer agentic tools
produced estimates consistent with modest speedups, but METR considers those estimates unreliable
because developers and tasks most favorable to AI selected out of the no-AI condition, and parallel
agents made time accounting difficult.
([early-2025 trial](https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/),
[2026 experiment update](https://metr.org/blog/2026-02-24-uplift-update/))

This does not mean current agents are unhelpful. It means Tilde should measure the whole loop:
delegation, waiting, review setup, correction, verification, and merge—not tokens, prompts, lines of
code, or agent runtime as proxies for value.

**Product implication:** success is reduced time to a safe decision, not more simultaneous agents.

### 3. Parallel agents make human attention and reconciliation scarce

OpenAI describes the Codex app as a command center for parallel, long-running agents and reports
that its heaviest internal users generate more than 60 hours of agent turns per day across parallel
agents. The human cannot watch that work synchronously.
([Codex app](https://openai.com/index/introducing-the-codex-app/),
[agents transforming work](https://openai.com/index/how-agents-are-transforming-work/))

A July 2026 study of 33,596 agent-authored pull requests across 2,807 repositories found exact-time
co-active agent PRs in 40.2% of repositories. Replayed textual merge conflicts occurred in 19.8% of
intra-agent pairs and 41.7% of cross-agent pairs. Textual conflicts are a lower bound because clean
merges can still be semantically incompatible.
([agent PR concurrency study](https://arxiv.org/abs/2607.04697))

Current product documentation also converges on the same control pattern:

- Codex provides parallel threads, worktrees, review, steering, and notifications.
- GitHub's agent-management surface centralizes active sessions, logs, steering, PR review, CI, and
  merge.
- Claude Code provides agent view, agent teams, shared tasks, hooks, and worktree isolation.
- Cursor background agents expose status, follow-ups, takeover, and remote environments.

([GitHub agent management](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/agent-management),
[Claude Code parallel agents](https://code.claude.com/docs/en/agents),
[Cursor background agents](https://docs.cursor.com/background-agent))

**Product implication:** do not compete on the number of agents visible. Rank the few decisions that
need a human and identify branch collisions before merge.

### 4. Flow depends on feedback loops, cognitive load, and recovery

Microsoft and GitHub's Developer Experience research, based on more than 2,000 developers, found
support for flow state, low cognitive load, and fast feedback loops as drivers of individual and
team outcomes. The feedback-loop measure included getting questions answered and completing code
reviews.
([Microsoft DevEx research](https://azure.microsoft.com/en-us/blog/quantifying-the-impact-of-developer-experience/))

OpenAI's guidance for long-running Codex work emphasizes durable state, reviewable memory, bounded
decision points, and goals with verifiable definitions of done. It explicitly distinguishes what an
agent prepares from what the user must decide.
([Codex long-running work](https://cdn.openai.com/pdf/8a9f00cf-d379-4e20-b06f-dd7ba5196a11/OAI_WhitePaper_Codex-maxxing26.pdf))

**Product implication:** Tilde should make the next decision and its evidence legible in seconds,
then return the developer to the exact work surface.

### 5. Risk should determine review effort

OWASP's 2026 secure-coding guidance calls out agent-specific risks: out-of-scope edits, changes to
rules files and CI, prompt-to-code supply-chain changes, excessive permissions, and propagation
across agents. It recommends heightened review for workflow files, build scripts, dependency
configuration, agent instruction files, and unexpected paths.
([OWASP secure coding with AI](https://cheatsheetseries.owasp.org/cheatsheets/Secure_Coding_with_AI_Cheat_Sheet.html))

Meta's RADAR study describes a deployed risk-aware review funnel combining eligibility gates,
static heuristics, risk scoring, automated review, and deterministic validation. Across more than
535,000 reviewed diffs, the system routes higher-risk work to people instead of applying the same
review process to everything. Tilde should borrow the principle, not claim Meta's outcomes.
([RADAR paper](https://arxiv.org/abs/2605.30208))

**Product implication:** Tilde should tell the user *why* a change deserves attention and which
evidence is missing. It should never collapse this into an unexplained AI score.

## Market reality

The basic “agent mission control” idea is no longer a wedge.

| Product or surface | Already covers |
| --- | --- |
| Codex app | Multiple agents, worktrees, diff review, steering, notifications, automations, remote continuation |
| GitHub Copilot | Multi-provider sessions, live logs, steering, PR/CI review, agent merge |
| Claude Code | Parallel sessions, agent teams, worktrees, task state, lifecycle hooks |
| Cursor | Background agents, status, follow-ups, takeover, PR workflow |
| [Agetor](https://www.agetor.dev/) | Local kanban, worktrees, approvals, questions, transcripts, notifications |
| [lazyagent](https://lazyagent.dev/) | Eight-provider monitoring, activity, usage/cost, search, webhooks, menu bar |
| [AgentPeek](https://agentpeek.app/) | Seven-provider menu/notch monitor, approvals, tool history, 5-hour and 7-day limits |
| [Gent](https://usegent.com/) | Specs, phase gates, checks, retries, task graphs, cost |
| [Clash](https://clash.sh/) | Read-only worktree conflict detection using `git merge-tree` |

Implications for Tilde:

- More provider rows are necessary compatibility work, not differentiation.
- Usage bars are a utility, not a reason to install Tilde.
- Launching agents and managing worktrees would put Tilde into direct competition with mature,
  rapidly changing products.
- A transcript viewer conflicts with Tilde's privacy promise and is already common elsewhere.
- Generic CPU, RAM, disk, network, and fan cards compete with established system monitors and push
  the important agent decision below the fold.

The defensible combination is **ambient + cross-provider + change-centered + deterministic +
local-first**.

## Current Tilde audit

### What is worth keeping

- Herdr discovery and one-click focus prove the ambient handoff.
- Transition-only notifications are calmer than polling every terminal.
- `TrustPacketSnapshot` establishes the right product instinct: evidence, not AI confidence.
- Recovery capsules avoid persisting prompts, transcripts, or source.
- The native menu-bar implementation is appropriate for a small decision queue.
- System monitoring can remain as an abnormal-condition signal and a separate diagnostics view.

### What is not reliable enough yet

#### Trust is scoped to one selected checkout

`DiagnosticViewModel` chooses one preferred project—the focused agent, otherwise the first working
agent—and computes one trust packet. Three ready branches therefore do not produce three reviewable
change records.

#### Committed changes can disappear

`TrustPacketProvider` reads `git status --porcelain`, `git diff`, and `git diff --cached`. Once an
agent commits its work, a clean checkout can report `Clean · no local changes` even when its branch
contains a large change against `main`.

#### Passing evidence is not bound to the change

The build pulse observes developer processes globally. It does not record the repository, worktree,
Git fingerprint, exact command, or output identity that passed.

#### CI may belong to another branch

`ProjectContextMonitor` asks `gh run list --limit 1` and does not filter by branch or head SHA. A
successful run on another branch can be displayed next to the active change.

#### “Ready” is overloaded

A clean checkout becomes ready even without required checks. “No local modifications,” “no known
risks,” and “all required checks passed for this exact diff” are different facts and must not share
one green state.

#### Attention state is provider-thin

Tilde trusts Herdr's coarse `blocked`, `working`, `done`, and `idle` state and has no first-party
Codex or Claude adapter. Codex App Server already exposes thread runtime status and
`thread/status/changed`; Claude exposes lifecycle and notification hooks. Supported events should
replace process or terminal heuristics wherever possible.
([Codex App Server](https://learn.chatgpt.com/docs/app-server#api-overview),
[Claude hooks](https://code.claude.com/docs/en/hooks-guide))

### What the interface currently gets wrong

The menu popover gives large permanent areas to CPU, RAM, fan, disk, network, and quota. The trust
row, recovery state, and next action appear later in a scrolling panel. This inverts the proposed
value hierarchy.

Apple's guidance says a popover should expose a small amount of information and a few related tasks.
Tilde should show decisions in the popover and move detailed diagnostics into the full window.
([Apple popover guidance](https://developer.apple.com/design/human-interface-guidelines/popovers/))

## Product definition

### One-sentence promise

**Tilde tells you which agent-produced change needs you next and whether its evidence is still
valid.**

### Primary user

A macOS developer who regularly runs two or more coding-agent tasks across one or more repositories
and remains accountable for reviewing, testing, reconciling, and merging the result.

### Core jobs

1. **Triage:** Show only work that needs human judgment now.
2. **Understand:** Summarize the change shape and risk without storing source or trusting agent prose.
3. **Verify:** Run or ingest configured checks and bind the receipt to the exact change.
4. **Reconcile:** Warn when active branches overlap or no longer merge cleanly.
5. **Resume:** Return to the exact agent, worktree, diff, PR, or failed check.

### The durable object: `ChangeSet`

An agent session is an input to a change. Tilde's durable record should instead include:

- canonical repository identity;
- base ref and merge-base OID;
- branch and worktree path;
- head OID plus staged, unstaged, and untracked fingerprints;
- provider/session references when available;
- changed-path categories and deterministic risks;
- matching PR and CI head SHA;
- verification receipts and freshness;
- merge/conflict state against the base and other active changes.

No prompt, transcript, source, raw diff, credential, or account email needs to be persisted.

## Priority scorecard

Scores are directional, from 1 (weak) to 5 (strong), based on evidence strength, daily frequency,
differentiation, feasibility for the existing Swift app, and fit with Tilde's trust/privacy model.

| Opportunity | Evidence | Frequency | Wedge | Feasibility | Fit | Total / 25 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Exact, fresh verification receipts | 5 | 5 | 5 | 4 | 5 | **24** |
| Risk-ranked human decision queue | 5 | 5 | 4 | 4 | 5 | **23** |
| Scope drift and sensitive-change guide | 5 | 4 | 5 | 4 | 5 | **23** |
| Worktree conflict and stale-base radar | 4 | 3 | 4 | 5 | 5 | **21** |
| Change-centered recovery capsules | 4 | 4 | 3 | 4 | 5 | **20** |
| Supported provider adapters | 3 | 4 | 2 | 3 | 4 | **16** |
| Accurate quota windows | 2 | 4 | 1 | 4 | 3 | **14** |
| Agent orchestration / kanban | 3 | 4 | 1 | 2 | 3 | **13** |
| Always-visible system metrics | 2 | 2 | 1 | 5 | 2 | **12** |

## The proposed experience

### Menu-bar title

Default to the quietest truthful state:

- `~` when nothing needs the user;
- `~ 2` when two decisions are waiting;
- `~ !` for a failed or stale verification that the user asked Tilde to watch.

Quotas, branch names, active-agent names, CPU, and focus modes should not consume permanent menu-bar
width. Users can opt into one compact secondary signal in settings.

### Popover

The first screen should fit without scrolling in the normal case:

1. **Needs you** — up to three decision cards, highest risk first.
2. **Working** — one collapsed summary, expandable only on demand.
3. **Footer** — quota reset warning and machine-health warning only when relevant.

Example decision card:

```text
Tilde · research/receipt
Ready to review · 2 risks

✓ Tests · 18s             exact change
! CI unknown              no matching head SHA
! AGENTS.md changed       instruction surface

[Review change]  [Open agent]
```

### Full window

The full window should own depth:

- Review Queue
- Active Changes
- Verification Receipt
- Conflicts
- Usage
- Machine Diagnostics
- Settings

Do not put a full diff editor or transcript reader in Tilde. Deep-link to the user's existing editor,
Git client, provider app, or pull request.

## Verification receipt design

### Change identity

A receipt must be invalidated by any material change. A practical fingerprint can hash:

```text
repository identity
+ base OID
+ HEAD OID
+ index tree / staged diff hash
+ unstaged binary diff hash
+ untracked path, mode, size, and content hashes
+ verification profile hash
```

Tilde may compute source hashes in memory but should persist only the resulting fingerprint and
metadata.

### Receipt states

- `unconfigured` — no required verification profile exists;
- `missing` — checks are configured but have not run for this fingerprint;
- `running` — an explicit check is running;
- `failed` — one or more required checks failed;
- `partial` — some required evidence is missing or unavailable;
- `verified` — every required check passed for this exact fingerprint;
- `stale` — the fingerprint changed after evidence was collected.

“Clean,” “low risk,” and “verified” must remain separate labels.

### Check provenance

Each check receipt should include:

- stable check identifier and display name;
- command/profile version hash;
- start and end timestamps;
- exit status and duration;
- repository/worktree identity;
- change fingerprint;
- CI provider, run ID, URL, and head SHA when applicable;
- whether the result is exact, inferred, or unavailable.

Raw command output may be shown ephemerally but should not be persisted by default.

### Verification profile

Use a small, reviewable repository file rather than guessing commands from prose. One possible
shape is `.tilde/verify.json`:

```json
{
  "version": 1,
  "base": "origin/main",
  "checks": [
    { "id": "tests", "name": "Tests", "command": "./Scripts/test.sh", "required": true },
    { "id": "build", "name": "Build", "command": "swift build", "required": true }
  ]
}
```

Running repository commands is a trust boundary. Tilde must show the exact command and require
explicit trust for a new or changed profile. A changed profile invalidates prior receipts.

## Deterministic risk guide

Start with explainable rules, not an LLM score:

- large path or line-count change;
- application code changed without a matching test-area change (advisory, never universal truth);
- auth, permission, credential, entitlement, or encryption paths;
- database schemas and migrations;
- dependency manifests and lockfiles;
- CI, deployment, Docker, build, and package scripts;
- agent instruction, skill, hook, MCP, and rules files;
- executable or binary additions;
- unexpected paths outside an optional task scope;
- branch behind base;
- no matching CI head SHA;
- check evidence stale after a change;
- merge conflict or overlapping high-risk paths with another active change.

Every warning should state the observed fact and the recommended human action. Avoid labels such as
“92% safe.”

## Phased roadmap

### Phase 0 — Make existing claims truthful

Goal: Tilde never displays “evidence ready” for evidence that is missing, stale, or attached to a
different change.

- Rename current trust states to factual language until exact receipts exist.
- Compare committed and uncommitted work against a configured or resolved base.
- Match CI by repository and head SHA.
- Separate `clean`, `risk`, and `verification` state.
- Show both Codex 5-hour and 7-day windows by duration, never by `primary`/`secondary` position.
- Add tests for committed-only changes, wrong-branch CI, stale evidence, untracked files, detached
  HEAD, no upstream, and worktrees.

Exit gate: zero known false-green cases in fixtures and 20 dogfood changes.

### Phase 1 — Exact local verification receipts

Goal: one click produces durable proof for the exact local change.

- Add `ChangeSet`, `ChangeFingerprint`, `VerificationProfile`, and `CheckReceipt` models in
  `TildeCore`.
- Add an explicit check runner with cancellation, timeout, and ephemeral output.
- Persist receipt metadata under Application Support.
- Invalidate immediately when Git or the profile changes.
- Render missing, running, failed, verified, and stale states.
- Deep-link to the worktree and failed check.

Exit gate: a user can answer “what passed, when, for which exact change?” in under five seconds.

### Phase 2 — Change-centered decision queue

Goal: the popover becomes useful several times per day without becoming another workspace.

- Discover all active Git worktrees and branches associated with detected agents.
- Create one card per change, not per process.
- Rank: needs input, verification failed, ready-but-unverified, verified review, working, idle.
- Make system metrics exception-only in the popover.
- Move full diagnostics, usage history, and fan control into the main window.
- Add `Review change`, `Run missing checks`, `Open agent`, and `Open PR` actions.

Exit gate: at least 90% of surfaced cards lead to the correct next action during dogfooding.

### Phase 3 — Risk and scope

Goal: focus scarce review time where it matters.

- Expand deterministic path categories using OWASP's agentic coding guidance.
- Add an optional task scope: intended outcome, expected paths, and acceptance checks.
- Flag out-of-scope paths and changed agent instruction surfaces.
- Produce a review recipe, not an AI summary.
- Copy a compact Markdown receipt for PR descriptions or handoff.

Exit gate: every warning is explainable from local facts; false-positive rate stays below 10% in
dogfooding.

### Phase 4 — Conflict radar

Goal: find parallel-work costs before review or merge.

- Discover linked worktrees with `git worktree list --porcelain`.
- Use `git merge-tree` to simulate merges without touching the checkout.
- Detect same-file and high-risk-area overlap across active changes.
- Distinguish textual conflict from semantic-overlap advisory.
- Show base drift and suggest a review/merge order, clearly labeled as a recommendation.

Exit gate: every deliberately seeded textual conflict is found before merge; no repository mutation
occurs during detection.

### Phase 5 — Supported provider adapters

Goal: Tilde sees work wherever it was started without owning the runtime.

- Codex: App Server thread list/status notifications, cwd, Git metadata, approvals where supported.
- Claude Code: lifecycle/notification hooks and agent-team state, installed only with consent.
- Cursor: supported Background Agent API when configured; otherwise label observation as partial.
- Herdr: retain the existing CLI adapter.
- Normalize provider state while preserving source and confidence (`exact`, `inferred`,
  `unavailable`).

Exit gate: one provider failure cannot break Git discovery or verification.

## What to pause or demote

Until the core loop proves useful:

- Do not build a kanban board, agent launcher, terminal, transcript search, or diff editor.
- Do not add more always-visible system cards.
- Do not expand the session diary as an activity score.
- Do not use lines changed, prompts, tokens, commits, or agent hours as productivity metrics.
- Do not add AI-generated confidence, summaries, or review comments before deterministic evidence is
  correct.
- Do not persist prompts, transcripts, command output, source, or diffs.
- Keep fan control and detailed machine diagnostics available, but outside the primary decision
  flow.

## Validation study

Research can justify a bet, not prove the product. Run a two-week, 20-change dogfood study before
expanding scope.

### Baseline: 10 agent-produced changes

Record locally:

- time from agent completion to opening the correct change;
- time spent reconstructing branch/worktree/task context;
- commands rerun manually to establish confidence;
- wrong-branch or stale evidence incidents;
- correction loops after first review;
- merge conflicts discovered late;
- self-rated decision confidence from 1 to 5.

### Tilde receipt flow: next 10 comparable changes

Measure the same outcomes plus:

- decision cards shown and acted on;
- false or irrelevant attention cards;
- receipt invalidations correctly triggered;
- warnings accepted, dismissed, or repeatedly ignored;
- time from opening Tilde to taking the next action.

### Success criteria

- zero false `verified` states;
- at least 30% lower median review-setup/recovery time;
- at least 90% of decision cards identify the correct next action;
- less than 10% irrelevant risk warnings;
- all intentionally seeded worktree conflicts detected before merge;
- background CPU below 1%;
- no persisted source, diff, prompt, transcript, raw output, email, or credentials;
- the user chooses to open Tilde for at least half of ready-to-review handoffs without being reminded.

If Tilde misses these gates, do not add providers to hide the failure. Revisit the decision-card and
receipt model.

## Recommended first implementation slice

The smallest slice that tests the thesis is:

1. Register one repository and base ref.
2. Discover its worktrees.
3. Compute a full committed-plus-uncommitted `ChangeFingerprint` for each worktree.
4. Configure one test command and one build command.
5. Run them explicitly and store fingerprint-bound receipt metadata.
6. Show one popover card with `missing`, `failed`, `verified`, or `stale` evidence.
7. Open the exact worktree when clicked.

This slice is more valuable than adding five providers because it proves—or disproves—the unique
reason for Tilde to exist.

## Final product principle

Agents already know how to work. Tilde should help the human know when to look, what to question,
and whether the evidence still applies.
