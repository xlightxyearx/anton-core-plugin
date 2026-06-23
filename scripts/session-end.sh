#!/usr/bin/env bash
# Plugin hook: SessionEnd
# shellcheck source=lib/wrapper.sh disable=SC1091
source "$(dirname "$0")/lib/wrapper.sh"

_extract_session_id
if [[ -n "$SESSION_ID" ]]; then
    set -- --session-id "$SESSION_ID" "$@"
fi
if [[ -n "$TRANSCRIPT_PATH" ]]; then
    set -- --transcript-path "$TRANSCRIPT_PATH" "$@"
fi

# Background prefetch; never blocks SessionEnd. Stderr is tee'd to a data-dir
# log (mirroring session-start.sh) so a silent prefetch failure — asset
# missing, disk full, arch mismatch — leaves a forensic trail instead of
# vanishing into /dev/null. The orchestrator additionally records
# PREFETCH_FAILED (verification) / PREFETCH_DEFERRED (transient) rows in
# events_log for the /health and `update status` surfaces.
LOG_DIR="${CLAUDE_PLUGIN_DATA:-/tmp}/data/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
("$ANTON_BIN" update prefetch --quiet --budget 60s 1>/dev/null 2>>"$LOG_DIR/update.err" &)

# Best-effort: reap a session-scoped dashboard server on the default port.
# LISTEN-filtered (a bare port query also matches established browser
# sockets) and command-matched against the dashboard binary's basename —
# anchored so every install layout matches (`anton-core` pinned/dev,
# `anton-core-vX.Y.Z` bootstrap) and a foreign command line that merely
# contains similar words (e.g. `encore dashboard`) never does. Insurance
# behind Claude Code's own background-task teardown; custom-port instances
# rely on that teardown alone. Each kill (or failed attempt) appends one
# line to the data-dir log so the reap leaves a forensic trail instead of
# vanishing into /dev/null. Guarded by scripts/lib/wrapper_test/session_end_reap.bats.
if command -v lsof >/dev/null 2>&1; then
    for pid in $(lsof -ti tcp:7777 -sTCP:LISTEN 2>/dev/null); do
        if ps -o command= -p "$pid" 2>/dev/null | grep -Eq '(^|/)anton-core[^/ ]* dashboard( |$)'; then
            if kill "$pid" 2>/dev/null; then
                echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) reaped dashboard pid $pid (port 7777)" >>"$LOG_DIR/dashboard-reap.log" 2>/dev/null || true
            else
                echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) kill failed for dashboard pid $pid (port 7777)" >>"$LOG_DIR/dashboard-reap.log" 2>/dev/null || true
            fi
        fi
    done
fi

# Orphan sweep: reap any core-dashboard whose parent is already init (ppid==1)
# — abnormal-session-exit leftovers on a non-default port. A live session's
# dashboard has ppid=its session, never 1, so this never touches another
# session's server. Complements the in-process self-reap watchdog and is the
# only path that reaps pre-watchdog orphans.
if command -v pgrep >/dev/null 2>&1; then
    for pid in $(pgrep -f 'dashboard' 2>/dev/null); do
        ps -o command= -p "$pid" 2>/dev/null | grep -Eq '(^|/)anton-core[^/ ]* dashboard( |$)' || continue
        [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "1" ] || continue
        if kill "$pid" 2>/dev/null; then
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) reaped orphan dashboard pid $pid (ppid=1)" >>"$LOG_DIR/dashboard-reap.log" 2>/dev/null || true
        fi
    done
fi

# Best-effort: reap orphaned data/bin subdirs left in superseded Claude Code
# plugin-cache version dirs. Proceeds ONLY when CLAUDE_PLUGIN_ROOT sits inside
# the CC plugin cache (…/plugins/cache/anton-core/…); dev checkouts and data
# dirs are never swept. Only the data/bin subdir is removed — CC owns the
# version-dir envelope and the current version is never touched. Concurrent
# session-ends double-reap harmlessly: rm -rf on an already-gone dir is a
# no-op under || true, and the [ -d ] guard turns the second pass into a clean
# skip.
#
# Path-confinement: the case globs match the LITERAL path, which a `..`-laden
# CLAUDE_PLUGIN_ROOT or a symlinked version-dir/data component could point out
# of the cache subtree while still reading …/plugins/cache/anton-core/…. So the
# delete is gated on the CANONICAL path: `cd … && pwd -P` (bash 3.2 has no
# realpath) resolves `..` and symlinked intermediates, and an escaped target no
# longer matches the anton-core glob, so it is skipped. A root carrying a `..`
# path component is also refused outright up front. The final `bin` is
# re-appended unresolved so a symlinked bin is unlinked by rm, never followed.
# Guarded by scripts/lib/wrapper_test/session_end_cache_reap.bats.
case "$CLAUDE_PLUGIN_ROOT" in
    */plugins/cache/anton-core/*)
        # Refuse to reap from a root with a `..` component (slash-bounded so a
        # literal `foo..bar` dir name is not mistaken for traversal).
        case "/$CLAUDE_PLUGIN_ROOT/" in
            */../*) : ;;
            *)
                _cache_root="$(dirname "$CLAUDE_PLUGIN_ROOT")" || true
                _cur="$(basename "$CLAUDE_PLUGIN_ROOT")" || true
                for d in "$_cache_root"/*/data/bin; do
                    [ -d "$d" ] || continue
                    ver="$(basename "${d%/data/bin}")" || true
                    [ "$ver" != "$_cur" ] || continue
                    # Canonicalise the parent before deleting; re-append the
                    # unresolved `bin` (a symlinked bin is then unlinked, not
                    # followed). cd failure → skip (best-effort).
                    _real="$(cd "${d%/bin}" 2>/dev/null && pwd -P)" || continue
                    case "$_real/bin" in
                        */plugins/cache/anton-core/*)
                            rm -rf "$d" 2>/dev/null || true
                            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) reaped cache binary dir $d (ver=$ver cur=$_cur root=$CLAUDE_PLUGIN_ROOT)" >>"$LOG_DIR/cache-reap.log" 2>/dev/null || true
                            ;;
                    esac
                done
                ;;
        esac
        ;;
esac

# Best-effort: fire a consolidation pass (Link always; Dream/RunAll on their
# own cooldowns). Detached + --quiet so SessionEnd never blocks on an LLM pass;
# the maintenance file-lock serializes against any concurrent consolidate, and
# stderr is appended to a data-dir log so a silent failure leaves a trail.
("$ANTON_BIN" maintenance consolidate --quiet 1>/dev/null 2>>"$LOG_DIR/consolidate.err" &)

exec "$ANTON_BIN" hook session-end "$@"
