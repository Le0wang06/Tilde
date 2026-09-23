# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

- Preferred: GitHub private vulnerability reporting on [Le0wang06/Tilde](https://github.com/Le0wang06/Tilde/security/advisories/new).
- Alternative: email 098leowang@gmail.com with "Tilde security" in the subject.

Include the macOS version, the Tilde commit or version, and steps to reproduce. Do not include prompts, diffs, terminal output, or tokens in the report; describe them instead. You should hear back within seven days.

## Scope

Tilde is a local macOS menu-bar app with two command-line tools. There is no Tilde server, account, telemetry, or update channel.

Network activity is limited to:

- Cursor usage API over HTTPS (`api2.cursor.sh`), called with the access token Tilde reads from Cursor's local `state.vscdb`. The token is held in memory for the request and never written by Tilde.
- The Codex app server, which Tilde launches as a local child process (`codex app-server --listen stdio://`) and talks to over stdio. No sockets are opened.

Everything else is local: Herdr is invoked as a CLI, git is read for worktree and fingerprint data, IOKit and SMC are read for sensors, and verification checks run the commands a repository declares in `.tilde/verify.json`.

In scope:

- Persisting data the privacy contract forbids (see below).
- Verification checks running without an explicit Trust & Run for that repository and profile hash, or running after the profile changed without re-trusting.
- Symlink or path tricks in `.tilde/verify.json` handling.
- `tilde://` deep links triggering actions they should not.
- Fan control (`tilde-fan`, SMC writes) doing anything beyond fan speed, or escalating privileges beyond the single admin prompt.
- Leaking the Cursor token or Codex output to disk or logs.

Out of scope:

- Vulnerabilities in Herdr, Codex, Cursor, or macOS themselves.
- Commands a user chose to place in their own `.tilde/verify.json`.

## Privacy contract

Tilde never persists prompts, terminal output, source code, diffs, authentication tokens, or account email. Only metadata is stored, under `~/Library/Application Support/Tilde`: spend counters, verification receipt hashes and outcomes, decision-queue paths and reasons, diary summaries, and recovery hints. A report that shows Tilde writing anything outside that list is treated as a security issue.
