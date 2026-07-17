# AI development decision plane

The evidence-backed product direction and competitive study now lives in
[Making Tilde genuinely useful](Tilde-Usefulness-Study.md). This document remains the compact
implementation brief.

## Product promise

Tilde should answer four questions from the macOS menu bar:

1. What needs me?
2. What changed?
3. What evidence says it is safe?
4. Where should I resume?

Herdr and provider apps remain responsible for agent processes. Editors and Git clients remain
responsible for source navigation and full diff review. Tilde is the ambient, local-first decision
and verification layer between them.

The durable object is the change, not the agent. Agent sessions can stop, restart, or hand off while
the branch, worktree, risk, and verification receipt remain.

## Shipped foundation

- Live Herdr agent inventory with repository and branch resolution
- Attention ordering for blocked and completed agents
- Transition-only notifications with stable per-agent identifiers
- One-click focus back to the exact Herdr terminal
- Deterministic trust packets based on Git, build, CI, and upstream evidence
- Local recovery capsules containing metadata and next-action guidance
- Session-diary events for agent blockers and completions

## Research correction

The shipped trust packet is a prototype, not yet a proof receipt. It currently evaluates one
selected checkout, can miss committed branch changes, observes builds without binding them to an
exact Git fingerprint, and may show the latest CI run even when it belongs to another branch.

Until exact receipts ship, `clean`, `risk`, and `verified` must be treated as separate facts.

## Next increments

### Truthful change identity

Discover active worktrees, compare committed and uncommitted work against the correct base, and
compute a privacy-preserving fingerprint for every change.

### Exact verification receipts

Launch repository-configured build, test, lint, secret, and dependency checks through Tilde so
exit status and duration can be attached to the exact fingerprint. Invalidate the receipt as soon
as Git state or verification configuration changes. External process detection remains context, not
proof.

### Decision queue

Replace the metric-heavy primary popover with risk-ranked change cards. Surface missing or failed
evidence, human questions, and ready-to-review changes first. Keep working agents collapsed and show
machine metrics only when abnormal.

### Scope and conflict radar

Flag sensitive and out-of-scope paths with explainable rules. Use read-only Git merge simulation to
find worktree conflicts and base drift before the merge queue.

### Multi-provider attention

Use supported Codex App Server events, Claude lifecycle hooks, Cursor APIs when configured, and the
existing Herdr CLI. Normalize state while preserving whether each signal is exact, inferred, or
unavailable.

### Local validation

Measure review setup time, stale-evidence incidents, false attention, verification retries, and
late conflicts locally. Avoid lines-of-code, prompt-count, commit-count, token, or agent-runtime
productivity scoring.

## Release gates

- Background CPU remains below 1% during ordinary idle monitoring.
- Initial discovery never produces notification spam.
- No false `verified` state occurs in fixtures or dogfooding.
- At least 90% of decision cards identify the correct next action.
- Irrelevant deterministic risk warnings remain below 10%.
- Prompts, terminal output, source, diffs, account email, and credentials are not persisted.
- Every provider can fail independently without breaking system monitoring.
