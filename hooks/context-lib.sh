#!/usr/bin/env bash
# context-lib.sh — Compatibility shim for the split domain library architecture.
#
# This file was formerly a 2,221-line monolith. It has been split into focused
# domain libraries for lazy loading. This shim sources all split libraries to
# maintain backward compatibility with hooks that source context-lib.sh directly.
#
# New hooks should use require_*() from source-lib.sh for minimal startup overhead.
# This shim ensures existing hooks work without modification.
#
# @decision DEC-SPLIT-001
# @title context-lib.sh decomposed into focused domain libraries with lazy loading
# @status accepted
# @rationale context-lib.sh was 2,221 lines sourced by every hook. Every hook paid
#   the full parse cost even for hooks that only need 1-2 functions. The split
#   creates a small always-loaded core (~200 lines) and larger domain libraries
#   loaded on demand via require_*() functions in source-lib.sh. Backward
#   compatibility maintained via this shim that sources all modules. No functional
#   changes — pure file reorganization.
#
# @decision DEC-SIGPIPE-001
# @title Replace echo|grep and awk|head pipe patterns with SIGPIPE-safe equivalents
# @status accepted
# @rationale Under set -euo pipefail, any pipe where the reader closes before the
#   writer finishes (SIGPIPE) propagates exit 141 and kills the hook. Two patterns
#   were dangerous: (1) `echo "$var" | grep -qE` in tight while-read loops over
#   large plan sections — each spawns a subshell+pipe, and on macOS the shell
#   delivers SIGPIPE to the writer when grep exits early; (2) multi-stage pipes
#   like `grep | tail | sed | paste` in get_research_status(). Fixes applied:
#   Pattern B — replace `echo "$_line" | grep -qE 'pat'` with `[[ "$_line" =~ pat ]]`
#   (no subshell, no pipe). Pattern E — replace multi-stage pipe with a single awk
#   program that collects, filters, and formats in one process. See DEC-SIGPIPE-001
#   in session-init.sh for Pattern A (awk|head → inline awk limit) and Pattern C
#   (echo|sed → bash parameter expansion).

# _SRCLIB_DIR must be set by source-lib.sh before context-lib.sh is sourced.
# If sourced directly (e.g., in tests), derive from BASH_SOURCE.
if [[ -z "${_SRCLIB_DIR:-}" ]]; then
    _SRCLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Source all domain libraries. Each guards against double-sourcing internally.
source "${_SRCLIB_DIR}/core-lib.sh"
source "${_SRCLIB_DIR}/git-lib.sh"
source "${_SRCLIB_DIR}/plan-lib.sh"
source "${_SRCLIB_DIR}/trace-lib.sh"
source "${_SRCLIB_DIR}/session-lib.sh"
source "${_SRCLIB_DIR}/doc-lib.sh"
