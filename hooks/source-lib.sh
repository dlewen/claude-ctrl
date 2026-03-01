#!/usr/bin/env bash
# Hook library bootstrapper — sources log.sh and context-lib.sh.
#
# Usage: source "$(dirname "$0")/source-lib.sh"
#
# All 29 hooks source this file to get logging and context utilities.
# Direct sourcing from the hooks/ directory — simple and reliable.
#
# @decision DEC-SRCLIB-001
# @title Direct hook library sourcing (replaces session-scoped caching)
# @status accepted
# @rationale The previous caching mechanism (d6635ce) cached hook libraries
#   per session to prevent race conditions during concurrent git merges. However,
#   when cache population failed (permissions, disk full, missing session ID),
#   the source commands for log.sh and context-lib.sh were never reached. Since
#   all 29 hooks source this file, a single cache failure bricked the entire
#   hook system with no recovery path. Direct sourcing eliminates the failure
#   mode entirely. The theoretical git-merge race condition is mitigated by
#   session-init.sh's smoke test that validates library sourcing on startup.
#
# @decision DEC-SPLIT-002
# @title source-lib.sh provides require_*() lazy loaders for domain libraries
# @status accepted
# @rationale context-lib.sh was 2,221 lines loaded by every hook. Splitting
#   into domain libraries (git-lib, plan-lib, trace-lib, session-lib, doc-lib)
#   reduces parse overhead for hooks that only need 1-2 functions. require_*()
#   functions provide idempotent lazy loading — calling require_git() twice is
#   safe. Existing hooks continue to use context-lib.sh (compatibility shim)
#   with zero changes required. New hooks can require only what they need.
#
# @decision DEC-PERF-001
# @title Hook timing instrumentation via EXIT trap
# @status accepted
# @rationale We need to measure real hook wall-clock time to validate the Phase 2
#   refactoring gains (claimed ~60ms per invocation vs. ~180-480ms before). The
#   EXIT trap approach adds <1ms overhead: two date calls + one printf append.
#   The trap fires on both clean exit and crash, so timing is always recorded.
#   nanosecond precision (date +%s%N) is used on Linux/macOS; the fallback to
#   second-level granularity on systems without %N support produces a "0ms"
#   reading rather than failing. The log file (.hook-timing.log) is append-only
#   with tab-separated fields: timestamp, hook_name, elapsed_ms, exit_code.
#   File lives in CLAUDE_DIR (default: ~/.claude) so it is co-located with
#   other state files and easy to rotate or grep. Writing errors are suppressed
#   (|| true) to prevent timing instrumentation from denying legitimate commands.

# --- Hook timing instrumentation — <5ms overhead ---
# Records wall-clock time for each hook invocation to .hook-timing.log
_HOOK_START_NS=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")
_HOOK_NAME="${BASH_SOURCE[1]:-unknown}"
_HOOK_NAME="$(basename "$_HOOK_NAME" .sh)"

_hook_log_timing() {
    local end_ns
    end_ns=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")
    local elapsed_ms=$(( (end_ns - _HOOK_START_NS) / 1000000 ))
    local claude_dir="${CLAUDE_DIR:-$HOME/.claude}"
    local timing_log="$claude_dir/.hook-timing.log"
    # Append: timestamp hook_name elapsed_ms exit_code
    printf '%s\t%s\t%d\t%d\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_HOOK_NAME" "$elapsed_ms" "$?" >> "$timing_log" 2>/dev/null || true
    # Corpus capture: when HOOK_CORPUS_CAPTURE=1, dump raw input to timestamped file
    # Used by scripts/extract-corpus.sh --capture mode to build a real-world input corpus.
    if [[ "${HOOK_CORPUS_CAPTURE:-}" == "1" && -n "${HOOK_INPUT:-}" ]]; then
        local corpus_dir="${claude_dir}/tests/corpus/${_HOOK_EVENT_TYPE:-unknown}"
        mkdir -p "$corpus_dir" 2>/dev/null || true
        printf '%s\n' "$HOOK_INPUT" > "$corpus_dir/$(date +%Y%m%d-%H%M%S)-${_HOOK_NAME}.json" 2>/dev/null || true
    fi
}
trap '_hook_log_timing' EXIT

# CWD recovery: if the shell's CWD was deleted (e.g., worktree removal between
# hook invocations), recover before any hook logic runs. Without this, $PWD
# lookups fail with ENOENT and all subsequent detect_project_root() calls
# return garbage. This guard runs before sourcing log.sh so it is always active.
[[ ! -d "${PWD:-}" ]] && { cd "${HOME}" 2>/dev/null || cd /; }

_SRCLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${_SRCLIB_DIR}/log.sh"
source "${_SRCLIB_DIR}/context-lib.sh"

# --- Lazy domain library loaders ---
# These functions load domain libraries on demand. Each is idempotent:
# calling require_git() twice is safe (second call is a no-op).
#
# Usage in hooks that want to minimize load time:
#   require_git
#   get_git_state "$PROJECT_ROOT"
#
# Or in hooks that use all domains (like session-init.sh):
#   source "${_SRCLIB_DIR}/source-lib.sh"  # loads everything via context-lib.sh

require_git() {
    [[ -n "${_GIT_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/git-lib.sh"
}

require_plan() {
    [[ -n "${_PLAN_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/plan-lib.sh"
}

require_trace() {
    [[ -n "${_TRACE_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/trace-lib.sh"
}

require_session() {
    [[ -n "${_SESSION_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/session-lib.sh"
}

require_doc() {
    [[ -n "${_DOC_LIB_LOADED:-}" ]] && return 0
    source "${_SRCLIB_DIR}/doc-lib.sh"
}
