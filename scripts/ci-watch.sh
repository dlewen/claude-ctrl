#!/usr/bin/env bash
# ci-watch.sh — Background CI watcher for GitHub Actions runs.
#
# Mirrors the update-check.sh pattern with lock file, PID management,
# exponential backoff polling, and atomic state file writes.
#
# @decision DEC-CI-003
# @title Background CI watcher with lock file and exponential backoff
# @status accepted
# @rationale Polling GitHub Actions from within a hook is too slow (gh run list
#   can take 2-5s). Running in background and writing results to a state file
#   allows hooks to read status instantly. Lock file prevents concurrent watchers.
#   Exponential backoff (30s→60s→120s→300s cap) reduces API calls without
#   sacrificing responsiveness on fast pipelines (<2min pipelines see a result
#   at the 30s poll). 30-minute total timeout prevents orphaned watchers.
#   Terminal states (success/failure) exit immediately after writing.
#   All failures write 'error' status — never leaves state file in a broken state.
#
# Usage: ci-watch.sh <project_root> [run_id]
#   project_root — absolute path to the project root
#   run_id       — optional GitHub Actions run ID to monitor specifically
#
# State file format: status|run_id|conclusion|branch|workflow|started_at|updated_at|url|write_timestamp
# Status values: pending, success, failure, error
#
# Lock file: $CLAUDE_DIR/.ci-watch-{phash}.lock (contains PID)
# Max runtime: 30 minutes

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
PROJECT_ROOT="${1:-}"
RUN_ID="${2:-}"

if [[ -z "$PROJECT_ROOT" ]]; then
    echo "Usage: ci-watch.sh <project_root> [run_id]" >&2
    exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "ci-watch.sh: project_root '$PROJECT_ROOT' is not a directory" >&2
    exit 1
fi

# Source ci-lib.sh for shared utilities
# Need to find hooks directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${SCRIPT_DIR}/../hooks"

# Source core-lib for atomic_write, project_hash, validate_state_file
if [[ -f "${HOOKS_DIR}/core-lib.sh" ]]; then
    # shellcheck source=../hooks/core-lib.sh
    source "${HOOKS_DIR}/core-lib.sh"
else
    echo "ci-watch.sh: cannot find core-lib.sh at ${HOOKS_DIR}/core-lib.sh" >&2
    exit 1
fi

if [[ -f "${HOOKS_DIR}/ci-lib.sh" ]]; then
    # shellcheck source=../hooks/ci-lib.sh
    source "${HOOKS_DIR}/ci-lib.sh"
else
    echo "ci-watch.sh: cannot find ci-lib.sh at ${HOOKS_DIR}/ci-lib.sh" >&2
    exit 1
fi

# Compute project hash for scoped lock file
PHASH=$(project_hash "$PROJECT_ROOT")
LOCK_FILE="${CLAUDE_DIR}/.ci-watch-${PHASH}.lock"

# Always clean up lock file on exit
cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# --- Lock file: prevent concurrent watchers ---
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        # Another watcher is live — exit silently
        exit 0
    fi
    # Stale lock — clean up and continue
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# --- Verify gh CLI is available ---
if ! command -v gh >/dev/null 2>&1; then
    write_ci_status "$PROJECT_ROOT" "error" "" "" "" "" "" "" ""
    exit 0
fi

# --- Write pending immediately ---
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
write_ci_status "$PROJECT_ROOT" "pending" "${RUN_ID:-}" "" "$CURRENT_BRANCH" "" "" "" ""

# --- Polling with exponential backoff ---
# Backoff schedule: 30s → 60s → 120s → 300s (cap)
# Total timeout: 30 minutes
MAX_RUNTIME=1800  # 30 minutes in seconds
BACKOFF=30        # Initial poll interval
BACKOFF_MAX=300   # Cap at 5 minutes
START_TIME=$(date +%s)

while true; do
    # Check timeout
    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TIME ))
    if [[ "$ELAPSED" -ge "$MAX_RUNTIME" ]]; then
        write_ci_status "$PROJECT_ROOT" "error" "${RUN_ID:-}" "timeout" "$CURRENT_BRANCH" "" "" "" ""
        exit 0
    fi

    # Sleep with backoff
    sleep "$BACKOFF"

    # Poll GitHub Actions
    if [[ -n "$RUN_ID" ]]; then
        # Specific run — use gh run view
        RUN_JSON=$(gh run view "$RUN_ID" --repo "$(gh -C "$PROJECT_ROOT" repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" \
            --json status,conclusion,headBranch,workflowName,startedAt,updatedAt,url,databaseId \
            2>/dev/null) || RUN_JSON=""
    else
        # Latest run on current branch
        RUN_JSON=$(gh run list \
            --branch "$CURRENT_BRANCH" \
            --limit 1 \
            --json status,conclusion,headBranch,workflowName,startedAt,updatedAt,url,databaseId \
            --jq '.[0]' \
            2>/dev/null) || RUN_JSON=""
    fi

    if [[ -z "$RUN_JSON" || "$RUN_JSON" == "null" ]]; then
        # No result — try again with longer backoff
        BACKOFF=$(( BACKOFF * 2 > BACKOFF_MAX ? BACKOFF_MAX : BACKOFF * 2 ))
        continue
    fi

    # Parse JSON fields
    GH_STATUS=$(echo "$RUN_JSON"     | grep -o '"status":"[^"]*"'     | head -1 | cut -d'"' -f4 || echo "")
    GH_CONCLUSION=$(echo "$RUN_JSON" | grep -o '"conclusion":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    GH_BRANCH=$(echo "$RUN_JSON"     | grep -o '"headBranch":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "$CURRENT_BRANCH")
    GH_WORKFLOW=$(echo "$RUN_JSON"   | grep -o '"workflowName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    GH_STARTED=$(echo "$RUN_JSON"    | grep -o '"startedAt":"[^"]*"'  | head -1 | cut -d'"' -f4 || echo "")
    GH_UPDATED=$(echo "$RUN_JSON"    | grep -o '"updatedAt":"[^"]*"'  | head -1 | cut -d'"' -f4 || echo "")
    GH_URL=$(echo "$RUN_JSON"        | grep -o '"url":"[^"]*"'        | head -1 | cut -d'"' -f4 || echo "")
    GH_RUN_ID=$(echo "$RUN_JSON"     | grep -o '"databaseId":[0-9]*'  | head -1 | cut -d':' -f2 || echo "${RUN_ID:-}")

    # Check if run is in terminal state
    if [[ "$GH_STATUS" == "completed" ]]; then
        # Map conclusion to our status vocabulary
        case "$GH_CONCLUSION" in
            success)
                write_ci_status "$PROJECT_ROOT" "success" "$GH_RUN_ID" "$GH_CONCLUSION" "$GH_BRANCH" "$GH_WORKFLOW" "$GH_STARTED" "$GH_UPDATED" "$GH_URL"
                ;;
            failure|cancelled|timed_out|startup_failure|action_required)
                write_ci_status "$PROJECT_ROOT" "failure" "$GH_RUN_ID" "$GH_CONCLUSION" "$GH_BRANCH" "$GH_WORKFLOW" "$GH_STARTED" "$GH_UPDATED" "$GH_URL"
                ;;
            skipped|neutral)
                write_ci_status "$PROJECT_ROOT" "success" "$GH_RUN_ID" "$GH_CONCLUSION" "$GH_BRANCH" "$GH_WORKFLOW" "$GH_STARTED" "$GH_UPDATED" "$GH_URL"
                ;;
            *)
                write_ci_status "$PROJECT_ROOT" "error" "$GH_RUN_ID" "$GH_CONCLUSION" "$GH_BRANCH" "$GH_WORKFLOW" "$GH_STARTED" "$GH_UPDATED" "$GH_URL"
                ;;
        esac
        exit 0
    fi

    # Still running — update pending status with current run info
    write_ci_status "$PROJECT_ROOT" "pending" "$GH_RUN_ID" "" "$GH_BRANCH" "$GH_WORKFLOW" "$GH_STARTED" "$GH_UPDATED" "$GH_URL"

    # Increase backoff for next poll
    BACKOFF=$(( BACKOFF * 2 > BACKOFF_MAX ? BACKOFF_MAX : BACKOFF * 2 ))
done
