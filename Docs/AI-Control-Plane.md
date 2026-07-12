# AI development control plane

## Product promise

Tilde should answer four questions from the macOS menu bar:

1. What needs me?
2. What changed?
3. What evidence says it is safe?
4. Where should I resume?

Herdr remains responsible for persistent terminal workspaces and agent processes. Editors
remain responsible for source navigation. Tilde is the ambient, local-first attention and
verification layer between them.

## Shipped foundation

- Live Herdr agent inventory with repository and branch resolution
- Attention ordering for blocked and completed agents
- Transition-only notifications with stable per-agent identifiers
- One-click focus back to the exact Herdr terminal
- Deterministic trust packets based on Git, build, CI, and upstream evidence
- Local recovery capsules containing metadata and next-action guidance
- Session-diary events for agent blockers and completions

## Next increments

### Explicit verification runs

Launch repository-configured build, test, lint, secret, and dependency checks through Tilde so
exit status and duration can be attached to the exact change set. External process detection
remains useful context but cannot reliably infer success.

### Multi-provider attention

Add provider adapters for direct Codex sessions and supported cloud agents. Normalize them into
the same attention model while keeping provider-specific capabilities behind each adapter.

### Review surface

Expand trust packets into a full review view with changed paths, check evidence, CI links, and
explicit risk explanations. Keep source display ephemeral and opt-in.

### Personal workflow intelligence

Measure polling avoided, blocked time, verification retries, and recovery time locally. Avoid
lines-of-code or prompt-count productivity scoring.

## Release gates

- Background CPU remains below 1% during ordinary idle monitoring.
- Initial discovery never produces notification spam.
- False blocked/done alerts remain below 5% in dogfooding.
- Prompts, terminal output, source, diffs, account email, and credentials are not persisted.
- Every provider can fail independently without breaking system monitoring.
