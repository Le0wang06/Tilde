## Summary

<!-- One or two sentences on what changed and why. Link the issue if there is one. -->

## User-visible behavior

<!-- What a person sees differently in the menu bar, panel, banners, or CLIs. Write "None" for internal-only changes. -->

## Privacy impact

<!-- Tilde is local-first. List every new value written to disk (Application Support, receipts, diary, decision queue).
     It must be metadata only: no prompts, terminal output, diffs, source code, tokens, or account email.
     Write "No new persisted data" if nothing changed. -->

## Verification performed

- [ ] `swift build`
- [ ] `./Scripts/test.sh`
- [ ] Manual panel check in light mode
- [ ] Manual panel check in dark mode
- [ ] `swift run tilde-probe` (if TildeCore monitoring or AI probes changed)

<!-- Note anything not run and why (for example, no Herdr installed, no fan hardware). -->

## Known limitations

<!-- What this does not cover, follow-ups, or platform gaps. -->

---

Checklist from `AGENTS.md`:

- [ ] Reusable monitoring and parsing logic lives in `TildeCore`; AppKit and SwiftUI wiring stays in `TildeDiagnosticsApp`.
- [ ] Branch is focused on one change and targets `main`.
- [ ] Codex-authored commits carry `Co-authored-by: Codex <codex@openai.com>`.
