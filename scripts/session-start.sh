#!/usr/bin/env bash
# Plugin hook: SessionStart
# shellcheck source=lib/wrapper.sh disable=SC1091
source "$(dirname "$0")/lib/wrapper.sh"

# Foreground apply-if-staged; budget-bounded so SessionStart never hangs.
# Stderr is tee'd to a data-dir log so apply failures don't pollute Claude
# Code's console.
LOG_DIR="${CLAUDE_PLUGIN_DATA:-/tmp}/data/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
"$ANTON_BIN" update apply-if-staged --quiet --budget 10s 1>/dev/null 2>>"$LOG_DIR/update.err" || true

# Seed ~/.anton-core/config.json with the resolved data root at the earliest
# authoritative moment (hooks get CLAUDE_PLUGIN_DATA → wrapper.sh set
# CORE_DATA_DIR). This makes the shim's config.json fallback (Bug 2 A1) work on
# first run, before setup Step 3b would otherwise write it. Best-effort.
"$ANTON_BIN" setup persist-data-dir >/dev/null 2>>"$LOG_DIR/update.err" || true

exec "$ANTON_BIN" hook session-start "$@"
