# Tilde contribution workflow

- Keep Tilde local-first. Do not persist prompts, terminal output, source code, account email, or authentication material.
- Put reusable monitoring and parsing logic in `TildeCore`; keep AppKit and SwiftUI wiring in `TildeDiagnosticsApp`.
- For implementation work, create a focused branch, run `./Scripts/test.sh` and `swift build`, commit all intended changes, push the branch, and open a pull request against `main`.
- **Merge races / follow-ups:** Before assuming work is on `main`, check whether the PR already merged (`gh pr view`). If README, docs, assets, or small follow-ups landed on a feature branch *after* that branch's PR merged, **commit and push them directly to `main`** (or cherry-pick onto `main` and push). Do **not** open another PR for work that missed the merge window.
- Commit as the configured user and append `Co-authored-by: Codex <codex@openai.com>` for Codex-authored changes.
- In pull requests, summarize user-visible behavior, privacy implications, verification performed, and known limitations.
