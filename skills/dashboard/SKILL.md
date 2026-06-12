---
name: dashboard
description: Launch or reuse the read-only browser dashboard as a session-scoped background server. Use for "dashboard", "open the dashboard", "show me the graph/memory/tasks in the browser", or "stop the dashboard".
allowed-tools: Bash, Read
---

## What it does

Serves the read-only browser dashboard on `http://127.0.0.1:7777` without tying up a terminal. The server runs as a background task owned by the current Claude Code session — it dies when the session ends (with the session-end hook's reap as deterministic insurance), so there are no PID files and nothing to daemonize. If a dashboard is already listening, the skill reuses it instead of starting a second one.

## When to use

- "dashboard", "open the dashboard", "show me the dashboard"
- "show me the graph / memory / tasks / sessions in the browser"
- "stop the dashboard", "kill the dashboard"
- `/anton-core:dashboard [surface]`

Surfaces: `overview` (default), `memory`, `repos`, `tasks`, `sessions`, `improvements`, `news`, `health`, `graph`.

## How

Default port is 7777. Honour an explicit operator port ("on port 8080") everywhere `$PORT` appears below; never pick a different port silently.

**Listener check** (shared by every path below): `lsof -ti tcp:$PORT -sTCP:LISTEN` — the LISTEN filter is required; a bare port query also matches established browser sockets and returns multiple PIDs, which breaks `ps -p`/`kill` quoting — then confirm each PID's `ps -o command= -p <pid>` output matches the dashboard binary: `grep -Eq '(^|/)anton-core[^/ ]* dashboard( |$)'`. The anchored pattern covers every install layout (`anton-core` pinned/dev, `anton-core-vX.Y.Z` bootstrap) and never matches a foreign command line that merely contains similar words (e.g. `encore dashboard`). Iterate per PID.

1. **Probe**: `curl -fsS -m 2 http://127.0.0.1:$PORT/healthz`.
   - Answers `ok` and the listener check matches → already running (this or another session). Open `http://127.0.0.1:$PORT/<surface path>` (`open` on macOS; otherwise print the URL) and stop here.
   - Answers (any body, `ok` or not) but no listening PID matches the dashboard binary → a foreign app owns the port. Report it and suggest an explicit alternative port; never reuse it, never kill it.
2. **Start** (probe failed — nothing listening, or the listener doesn't serve `/healthz`): run with the Bash tool and `run_in_background: true`:

   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/core" dashboard --port $PORT <surface>
   ```

   Do NOT detach — no `nohup`, no `disown`, no `setsid`. Session-scoped lifetime is the design: the server binds 127.0.0.1 only, opens the browser itself, and is torn down with this session's background tasks.
3. **Confirm**: re-probe `/healthz` up to 5 times, 1s apart. On success report the URL. On exhaustion, read the background task's output and relay its typed error verbatim — a missing data dir surfaces a precondition error (set `CORE_DATA_DIR`). Exception for the busy-port error: run the listener check first — a PID matching the dashboard binary means an existing dashboard is wedged on the port (it holds the bind but failed the probe); report it as unresponsive and offer the stop gesture instead of relaying the "try --port" hint. If the output carries no typed error (e.g. a slow cold start), relay the raw output and say the server has not bound yet.

**Stopping** ("stop the dashboard"): run the listener check, then `kill` each matched PID — plain SIGTERM; the server drains in-flight requests for up to 3 seconds. Kill only matching PIDs; report any non-matching PID on the port as a foreign listener left untouched (refuse entirely when nothing matches). Then verify: re-probe `/healthz` after ~4s (drain allowance) — report stopped when the probe fails, or that the port is still bound when it answers. Works even when an earlier session started the server.

## Output

- One line — `Dashboard: http://127.0.0.1:$PORT/<path>` — plus whether the server was started fresh or an existing one was reused.
- Lifecycle: the server lives until this session ends (background-task teardown, plus the session-end hook reap on port 7777) or until the stop gesture. Custom-port instances rely on session teardown alone.
- No DB writes — the dashboard is a read-only surface; the skill itself records nothing.
