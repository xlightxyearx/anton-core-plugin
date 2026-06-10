---
name: setup
description: State-aware concierge for the full anton-core install lifecycle. Use for "set up", "install anton-core", "initialize", "re-run setup", "configure anton-core", "update anton-core", "repair anton-core", "check anton-core status", or "uninstall anton-core".
allowed-tools: Read, Edit, Bash, AskUserQuestion
---

## What it does

State-aware installer and lifecycle surface for anton-core. On invocation it runs a **state probe** (no install-state change; it records one classification line to the events log), classifies the install (fresh / healthy-current / update-available / partial), and either runs a clean first-time setup straight through or opens a guided menu (Health check · Reconfigure · Update or Repair · Uninstall). Mechanical plumbing — binary bootstrap, data-root persistence, the operator-shell launcher, the version-pin verify-back gate, the bootstrap-lock — runs silently behind four named progress stages. Supports `--check` (status, no install-state change), `--re-onboard`, and `--uninstall [--purge-data]`. Every binary call routes through `${CLAUDE_PLUGIN_ROOT}/scripts/core`, which auto-fetches the per-platform artifact on first call (see [ADR-0032](../../docs/adr/0032-marketplace-binary-distribution.md)).

## When to use

- "set up", "install anton-core", "initialize", "re-run setup", "configure anton-core"
- "update anton-core", "repair anton-core", "check status", `/anton-core:setup`
- "uninstall anton-core"
- After a plugin update that ships a newer `claude-md-fragment.md`

## Conventions (apply throughout)

- Every binary call routes through `"${CLAUDE_PLUGIN_ROOT}/scripts/core" <verb>`. Never invoke a bare `core` from this body.
- `Edit` is the only mutator for `~/.claude/CLAUDE.md`; never `sed`/`awk`. Every step is a no-op when its precondition already holds.
- Operator prompts use `AskUserQuestion` (never stdin).
- Voice: neutral, warm, concise — no persona.

### Paste-input normalization (every operator-pasted string)

1. Strip leading/trailing whitespace (ASCII space, tab, `\r`, `\n`, `\v`, `\f`).
2. Convert CRLF and lone CR to `\n`.
3. Reject any paste containing non-printable bytes other than `\n` / `\t` — re-prompt once, then abort the step on a second occurrence.
4. For newline-separated pastes (repos), split AFTER normalization, trim each line, drop empties.

## Step 0 — Argument triage & flag validation

Parse the invocation args for `--check`, `--uninstall`, `--purge-data`, `--re-onboard`. Reject in prose before any work:

- `--purge-data` without `--uninstall` → "`--purge-data` is only valid with `--uninstall`."
- `--uninstall` with `--re-onboard` → "`--uninstall` and `--re-onboard` are mutually exclusive."
- `--check` with any of `--uninstall` / `--purge-data` / `--re-onboard` → "`--check` is mutually exclusive with the other flags."

Then route:

- `--uninstall` present → jump to **Uninstall**; do not run the probe-driven menu.
- `--check` present → run **Step 1 (State probe)**, print the classification and — when `core.db` exists — the health summary already gathered in Step 1.8 (no second call). On a fresh box there is no DB to report on, so print "fresh — nothing installed yet". Then exit without changing install state. (`--check` makes no install-state change; on an installed box it appends a health-log row and the probe records one classification line — both append-only observations; on a fresh box it writes nothing at all, since the probe makes no binary call.)
- otherwise → run **Step 1 (State probe)**, then **Step 2 (Routing)**.

## Step 1 — State probe (no install-state change)

Gather, without writing anything. **Read-only guard:** every `"${CLAUDE_PLUGIN_ROOT}/scripts/core" <verb>` other than `db` / `--help` / `--version` opens — and therefore *creates and schemas* — `core.db` + `events.db` on first contact (the binary auto-constructs the data layer for any DB-backed verb). So the probe makes **no binary call when `core.db` is absent**: every binary-backed signal below is gated on the Step 1.1 `core.db`-existence boolean and falls back to its fresh-box default. Classification needs only the file-existence and `Read` signals, which never touch the binary.

1. **DB presence:** `[ -f "${CLAUDE_PLUGIN_DATA}/data/core.db" ]` and the same for `events.db`. Capture both as booleans; the `core.db` boolean gates every binary call below.
2. **Fragment + pin:** `Read ~/.claude/CLAUDE.md` (a `Read`, never a binary call); detect the `<!-- anton-core:start -->` / `<!-- anton-core:end -->` sentinels. Pinned version — **only when `core.db` exists** — `"${CLAUDE_PLUGIN_ROOT}/scripts/core" config get --key fragment.version` (value is `null` when unset); when `core.db` is absent, treat the pin as `null` and skip the call.
3. **Shipped fragment version:** `Read ${CLAUDE_PLUGIN_ROOT}/claude-md-fragment.md` frontmatter `fragment-version`.
4. **Plugin version (display only):** `Read ${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` `.version`.
5. **Symlink state:** `readlink ~/.local/bin/core` → classify correct / legacy / dangling / collision / absent.
6. **Onboarding flag:** **only when `core.db` exists**, `"${CLAUDE_PLUGIN_ROOT}/scripts/core" onboarding check`; when `core.db` is absent, treat onboarding as not-shown and skip the call.
7. **Declines:** **only when `core.db` exists**, `config get --key onboarding.repos.declined` (and `.import.declined`, `.symlink.declined`); when `core.db` is absent, treat each decline as unset and skip the calls.
8. **Health severity:** only when `core.db` exists, `"${CLAUDE_PLUGIN_ROOT}/scripts/core" report health --full` → read `report.severity`. On a fresh box (no `core.db`), SKIP this call.

Classify (first match wins):

- `core.db` absent AND no fragment → **fresh**.
- `core.db` xor fragment present, OR symlink dangling/legacy/collision, OR health severity `critical` → **partial**.
- structure intact AND shipped fragment version > pinned → **update-available**.
- else → **healthy-current** (health ok/warning/degraded).

**Classification telemetry (append-only observation).** When `events.db` exists, record one line:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/core" event log --source setup --severity info --type SETUP_CLASSIFIED --subject <classification> --detail "pinned=<pin> shipped=<shipped> symlink=<state>"
```

On a fresh box (`events.db` absent — the health step was also skipped), DEFER this line to Step 3d (after `db init` creates the databases). A failed `event log` is a one-line warning, never a block. This is the only thing the probe writes, and it is an append-only observation — not an install-state change.

## Step 2 — Routing

Match in order (first match wins):

- **fresh** → run **Install** (Steps 3–7) straight through; no menu. `--re-onboard` does **not** short-circuit here: a fresh box has no seeded database for `repos add` / `bulk-import` to write to, and Install runs onboarding un-gated as its Step 6 anyway, so an explicit `--re-onboard` on a fresh box is subsumed by the full install.
- **`--re-onboard`** (non-fresh, no menu) → **Onboarding** directly (un-gated).
- **non-fresh** → render an `AskUserQuestion` menu that names the detected state, with options ordered by class:
  - healthy-current → Health check (recommended) · Reconfigure · Update or Repair · Uninstall
  - update-available → Update (recommended) · Health check · Reconfigure · Uninstall
  - partial → Repair (recommended) · Health check · Reconfigure · Uninstall

  Route the choice: Health check → **Health verify**; Reconfigure → **Onboarding**; Update → **Update**; Repair → **Repair**; Uninstall → **Uninstall**.

## Install (Steps 3–7)

### Step 3 — Stage 1: Foundation

Print `1/4 Foundation`. Run, in order:

a. `"${CLAUDE_PLUGIN_ROOT}/scripts/core" db init` — materializes `core.db` + `events.db`, applies migrations, seeds DEFAULT_CONFIG (`INSERT OR IGNORE`). Idempotent. Surface a non-zero exit as a setup-blocked notice naming the precondition `reason`.
b. `"${CLAUDE_PLUGIN_ROOT}/scripts/core" setup persist-data-dir` — records the resolved data root in `~/.anton-core/config.json`. Non-fatal: a failure is a one-line warning.
c. `"${CLAUDE_PLUGIN_ROOT}/scripts/core" setup get-token --format json`. **Exit 0:** read the token from stderr (single line, no decoding) and prepend `ANTON_GITHUB_TOKEN=<token>` to every subsequent `"${CLAUDE_PLUGIN_ROOT}/scripts/core"` call in this run; never print it. **Exit 3:** proceed without a token — do not prompt for `gh auth login`, do not abort (the token only raises news-poller rate limits).
d. **Deferred classification telemetry (fresh only).** When the probe classified **fresh** (so `events.db` did not exist at Step 1), record the now-deferrable line — `"${CLAUDE_PLUGIN_ROOT}/scripts/core" event log --source setup --severity info --type SETUP_CLASSIFIED --subject fresh --detail "first-run install"`. A failed `event log` is a one-line warning.

### Step 4 — Stage 2: Connect to Claude

Print `2/4 Connect to Claude`.

a. `Read` `${CLAUDE_PLUGIN_ROOT}/claude-md-fragment.md` (frontmatter carries `fragment-version`).
b. `Read` `~/.claude/CLAUDE.md` (treat absence as empty).
c. Sentinels present → `Edit` to replace the byte range between (and including) `<!-- anton-core:start -->` / `<!-- anton-core:end -->` with the new fragment body, keeping the sentinels. Absent → `Edit` to append the fragment body bracketed by a fresh sentinel pair at EOF.
d. **Version-pin verify-back gate:** compare shipped `fragment-version` to `config get --key fragment.version`; when advanced (or absent), `config set --key fragment.version --value <X.Y.Z>`, then re-read and refuse to advance until the read-back equals the written value.

### Step 5 — Stage 3: Shell access (optional)

Print `3/4 Shell access`. The whole stage is convenience; any failure is a one-line warning, then continue.

a. `"${CLAUDE_PLUGIN_ROOT}/scripts/core" update status >/dev/null 2>&1` to materialize `data/versions/current` (read-only; runs the one-shot legacy→versioned migration). Confirm `[ -L "${CLAUDE_PLUGIN_DATA}/data/versions/current" ]`; if absent, warn and continue.
b. `mkdir -p "${CLAUDE_PLUGIN_DATA}/data/bin"`. When `${CLAUDE_PLUGIN_DATA}/data/bin/core` is absent or `! cmp -s "${CLAUDE_PLUGIN_ROOT}/scripts/core-shim.sh" "${CLAUDE_PLUGIN_DATA}/data/bin/core"`, copy `scripts/core-shim.sh` into place and `chmod +x`. On `mkdir`/`cp` failure, warn and skip the rest of the stage.
c. `mkdir -p "$HOME/.local/bin"`, then point `${HOME}/.local/bin/core` → `${CLAUDE_PLUGIN_DATA}/data/bin/core` per the four-branch tree: absent → create; matching symlink → no-op; any other symlink (different path, dangling, or the legacy `scripts/core` target) → overwrite via `ln -sfn`; non-symlink (regular file/dir/device) → refuse to clobber, warn, continue. If `$HOME/.local/bin` is not on `$PATH`, print the shell-RC line to add (`export PATH="$HOME/.local/bin:$PATH"`) — do NOT edit the shell-RC.

### Step 6 — Stage 4: Your content (onboarding)

Print `4/4 Your content`. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/core" onboarding check`; if `shown: true` and `--re-onboard` was not present, skip to Step 7. Otherwise run **Onboarding**.

### Step 7 — Health verify + completion card

`"${CLAUDE_PLUGIN_ROOT}/scripts/core" report health --full`. On `report.severity == "critical"`, surface the failing check names + their `detail` fields and stop before the card. On healthy/warning/degraded, print the **Completion card**.

## Onboarding (sub-flow)

Render ONE `AskUserQuestion` panel collecting the steps below; **omit any step whose `onboarding.<step>.declined` reads `true`** unless `--re-onboard` is set:

- **Repos:** "Register repositories with anton-core? Paste absolute paths, one per line, or Skip."
- **Knowledge:** "Bulk-import a knowledge directory? Absolute path, or Skip."
- **Shell access:** (only if not already linked) "Add `core` to your shell PATH? Yes / Skip."

**Plan-recap:** summarize the chosen actions in one line (e.g. "register 3 repos · import ~120 files · add `core` to PATH") and confirm before any write.

**Execute:**

- **Repos:** normalize the paste; for each path, classify before registering. If the path holds a `.git`, it is a single repo → `"${CLAUDE_PLUGIN_ROOT}/scripts/core" repos add <path>`. If it has no `.git` but two or more immediate children do, warn and render a second `AskUserQuestion`: "<path> looks like a parent of multiple repositories. Register it as…" with "Parent of many (Recommended)" → `repos add <path> --type parent`, or "A single repository" → `repos add <path>`. Render `✓ <path> (slug: …)` / `✗ <path> — <reason>`. Per-path failures do not abort.
- **Import:** `"${CLAUDE_PLUGIN_ROOT}/scripts/core" item bulk-import --path <dir> --recursive --dry-run --format summary`. On `file_count == 0`, report and continue. Otherwise render `file_count` + `by_type` + `dropped_by_owner_filter`, confirm via a second `AskUserQuestion`, then re-run without `--dry-run` and render `imported` / `tasks_created` / `errors`.
- **Shell access:** if "Yes" and not already linked, run Step 5c.

**Persist declines:** for each Skipped step, `config set --key onboarding.<step>.declined --value true`. For each completed step, clear it with `config set --key onboarding.<step>.declined --value ""`.

`"${CLAUDE_PLUGIN_ROOT}/scripts/core" onboarding mark-shown` (failure is a warning).

## Repair (sub-flow)

Re-run Steps 3–6 gated on their preconditions, narrating ONLY what was out of sync (e.g. "Routing fragment was missing — restored." / "Symlink was dangling — repointed."). Steps already in order stay silent. End with Step 7.

## Update (sub-flow)

Re-run Stage 2 (fragment refresh + re-pin) and Stage 3 (launcher refresh); SKIP onboarding. Report "Routing updated v<old> → v<new>." End with Step 7.

## Health verify (menu action)

`"${CLAUDE_PLUGIN_ROOT}/scripts/core" report health --full`; print the severity and any failing checks with their `detail`. Writes nothing.

## Completion card

```
✓ anton-core — ready to use.

Try this next:
  /anton-core:save     "remember <a fact worth keeping>"
  /anton-core:recall    --code <symbol>
  /anton-core:summary   your daily briefing
```

When a repository was registered, name one in the `recall --code` line; when nothing was onboarded, collapse to `save` + `summary`. Never list a command that is not an installed skill.

## Uninstall

When `--uninstall` is present (or chosen from the menu):

1. **Pre-flight.** `"${CLAUDE_PLUGIN_ROOT}/scripts/core" setup uninstall [--purge-data] --dry-run --format json`. Capture `removed[*]` paths + `bytes`.
2. **Scope (skip when `--purge-data` already given).** `AskUserQuestion`: "Remove anton-core, keep my data" (default) vs "Remove everything, erase my data" (⚠ also deletes `~/.anton-core/data` — saved knowledge, tasks, logs; no undo). The erase choice sets `--purge-data`.
3. **Confirm.** Keep-data → a plain confirm listing each `removed[*]` path with humanized `bytes` and `kind`, the CLAUDE.md fragment-wipe callout (sentinel region is plugin-managed; hand-edits inside go with it), and the symlink-removal note. Erase-everything → require **typed confirmation**: "Type `erase` to confirm." Any other input cancels with zero mutation.
4. **Breadcrumb before removal.** Append one line — `<ISO-8601 timestamp>\t<resolved paths>\t<total bytes>\t<scope>` — to `~/.anton-core/data/logs/uninstall.log`. Best-effort: a write failure is a warning, never a block.
5. **Execute.** `"${CLAUDE_PLUGIN_ROOT}/scripts/core" setup uninstall [--purge-data] --format json` (acquires `${CLAUDE_PLUGIN_DATA}/data/bin/.bootstrap.lock`). Then `Read` `~/.claude/CLAUDE.md`; if sentinels present, `Edit` to delete the marker pair + body. Then `readlink ~/.local/bin/core`; if it resolves to `${CLAUDE_PLUGIN_DATA}/data/bin/core`, `rm -f ~/.local/bin/core`; otherwise warn ("not the launcher symlink, leaving in place") and continue.
6. **Summary card.** Resolved paths removed, bytes freed (sum of `removed[*].bytes`), the callout that per-project memory under `~/.claude/projects/.../memory/` is untouched, the callout that a subsequent install is treated as first-run, and the reminder to run `/plugin uninstall anton-core` to complete removal.

## Behavior

After a successful install, `core.db` + `events.db` exist at `${CLAUDE_PLUGIN_DATA}/data/`, schema'd and seeded; `~/.claude/CLAUDE.md` carries the fragment between the sentinel pair; `~/.local/bin/core` (when creation succeeded) points at the operator-shell launcher; `config get --key fragment.version` returns the shipped version. Re-running is idempotent — the probe + menu make no install-state change (they may append observation logs only) and every execution step is a no-op when its precondition holds. Spec: [docs/plugin-spec/07-skills/setup.md](../../docs/plugin-spec/07-skills/setup.md).
