#!/usr/bin/env bash
# scan-backlog.sh — Codebase debt marker scanner for Claude Code.
#
# Purpose: Scans a codebase for debt markers (TODO, FIXME, HACK, etc.) and
# correlates each finding with existing GitHub issues labeled claude-todo.
# Used by the /scan command to surface untracked technical debt.
#
# @decision DEC-BL-SCAN-001
# @title rg-based marker scanning with gh issue correlation
# @status accepted
# @rationale ripgrep (rg) is faster than grep for large codebases and natively
# respects .gitignore, eliminating the need for manual exclusion lists. A grep
# fallback ensures the tool works in minimal environments (CI, new machines).
# Issue correlation is best-effort (body text search) rather than strict
# reference matching: this gives useful signal without requiring developers to
# maintain exact file:line references in issue bodies. Exit codes follow the
# "no results = 1" convention used by grep/rg, making it pipe-friendly.
# Output formats (table/json) are separated to support both human inspection
# (/scan command) and programmatic consumption (future CI integration).
#
# Scan patterns: TODO, FIXME, HACK, XXX, OPTIMIZE, TEMP, WORKAROUND
#
# Usage: scan-backlog.sh [--format table|json] [<directory>]
#
# Options:
#   --format table  Human-readable markdown table (default)
#   --format json   JSON array of {file, line, type, text, issue_ref} objects
#
# Exit codes:
#   0  — Markers found and displayed
#   1  — No markers found
#   2  — Error (bad arguments, target directory not found)
#
# Dependencies: rg or grep (rg preferred), gh (optional — used for correlation)
# Env: CLAUDE_TODO_GLOBAL_REPO (override global repo for issue correlation)

set -euo pipefail

# --- Constants ---
GLOBAL_REPO="${CLAUDE_TODO_GLOBAL_REPO:-juanandresgs/cc-todos}"
TODO_LABEL="claude-todo"
MARKER_PATTERN='TODO|FIXME|HACK|XXX|OPTIMIZE|TEMP|WORKAROUND'
EXCLUDE_DIRS=(vendor node_modules .git archive _archive)

# --- Argument parsing ---
FORMAT="table"
TARGET_DIR=""

_usage() {
    cat <<'USAGE'
Usage: scan-backlog.sh [--format table|json] [<directory>]

Options:
  --format table   Human-readable markdown table (default)
  --format json    JSON array of objects

Arguments:
  <directory>      Directory to scan (default: git root or current directory)

Exit codes:
  0  Markers found
  1  No markers found
  2  Error
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --format)
            shift
            if [[ -z "${1:-}" ]]; then
                echo "ERROR: --format requires an argument (table|json)" >&2
                exit 2
            fi
            FORMAT="$1"
            if [[ "$FORMAT" != "table" && "$FORMAT" != "json" ]]; then
                echo "ERROR: --format must be 'table' or 'json', got: '$FORMAT'" >&2
                exit 2
            fi
            ;;
        --help|-h)
            _usage
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            _usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$TARGET_DIR" ]]; then
                echo "ERROR: multiple target directories specified" >&2
                exit 2
            fi
            TARGET_DIR="$1"
            ;;
    esac
    shift
done

# --- Resolve target directory ---
if [[ -z "$TARGET_DIR" ]]; then
    # Default: git root if in a repo, else current directory
    if GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
        TARGET_DIR="$GIT_ROOT"
    else
        TARGET_DIR="$PWD"
    fi
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: target directory not found: $TARGET_DIR" >&2
    exit 2
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"  # Normalize to absolute path

# =============================================================================
# Scanner: find debt markers
#
# Uses rg if available (faster, respects .gitignore natively), falls back to
# grep -rn. Output format: file:line:matched_text (rg --no-heading --line-number)
# =============================================================================
_build_exclude_args_rg() {
    local args=""
    for dir in "${EXCLUDE_DIRS[@]}"; do
        args="$args --glob !${dir}/**"
    done
    echo "$args"
}

_build_exclude_args_grep() {
    local args=""
    for dir in "${EXCLUDE_DIRS[@]}"; do
        args="$args --exclude-dir=${dir}"
    done
    echo "$args"
}

_scan_with_rg() {
    local extra_globs
    extra_globs=$(_build_exclude_args_rg)
    # shellcheck disable=SC2086
    rg --line-number --no-heading --with-filename \
        -e "$MARKER_PATTERN" \
        $extra_globs \
        "$TARGET_DIR" 2>/dev/null || true
}

_scan_with_grep() {
    local extra_excludes
    extra_excludes=$(_build_exclude_args_grep)
    # shellcheck disable=SC2086
    grep -rn \
        -E "$MARKER_PATTERN" \
        $extra_excludes \
        "$TARGET_DIR" 2>/dev/null || true
}

# Run scan, normalize output to: file<TAB>line<TAB>raw_text
# rg outputs: path:line:text
# grep -rn outputs: path:line:text
# Both use colon as separator, same format.
_run_scan() {
    if command -v rg >/dev/null 2>&1; then
        _scan_with_rg
    else
        _scan_with_grep
    fi
}

# =============================================================================
# Parser: extract marker type and text from a match line
#
# Input line: /path/to/file:42:    # TODO: fix this later
# Outputs: file, line_num, marker_type, text_after_marker
# =============================================================================
_parse_match_line() {
    local raw_line="$1"

    # Split file:line:text — handle paths with colons (unlikely but possible)
    # Format is guaranteed: absolute/path:lineno:matched_content
    local file line_num match_text

    # Use awk to split on first two colons only
    file=$(echo "$raw_line" | awk -F: '{print $1}')
    line_num=$(echo "$raw_line" | awk -F: '{print $2}')
    match_text=$(echo "$raw_line" | awk -F: '{$1=""; $2=""; sub(/^::/, ""); print}' | sed 's/^ *//')

    # Extract the marker type from the text
    local marker_type
    marker_type=$(echo "$match_text" | grep -oiE 'TODO|FIXME|HACK|XXX|OPTIMIZE|TEMP|WORKAROUND' | head -1 | tr '[:lower:]' '[:upper:]')

    # Extract text after the marker (strip leading colon, space, dash)
    local marker_text
    marker_text=$(echo "$match_text" | sed -E "s/.*${marker_type}[: -]*//" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    # Trim to reasonable length
    if [[ ${#marker_text} -gt 120 ]]; then
        marker_text="${marker_text:0:117}..."
    fi

    # Make file path relative to TARGET_DIR for cleaner display
    local rel_file="${file#$TARGET_DIR/}"

    printf '%s\t%s\t%s\t%s' "$rel_file" "$line_num" "$marker_type" "$marker_text"
}

# =============================================================================
# Issue correlation: match markers against open GitHub issues
#
# Queries gh issue list --label claude-todo and checks each issue's body/title
# for references to the file path. Best-effort — misses inline comments.
#
# Populates global associative-style array: ISSUE_MAP_FILE and ISSUE_MAP_REF
# =============================================================================
# We use parallel arrays (bash 3.2 compatible — no declare -A)
ISSUE_NUMS=()
ISSUE_TITLES=()
ISSUE_BODIES=()
GH_AVAILABLE=false

_load_issues() {
    if ! command -v gh >/dev/null 2>&1; then
        return 0
    fi

    local raw_issues
    raw_issues=$(gh issue list \
        --label "$TODO_LABEL" \
        --state open \
        --json number,title,body \
        --limit 200 \
        2>/dev/null) || return 0

    GH_AVAILABLE=true

    # Parse JSON array — extract each issue's number, title, body
    # Use python3 if available (jq may not be installed)
    if command -v python3 >/dev/null 2>&1; then
        while IFS=$'\t' read -r num title body; do
            ISSUE_NUMS+=("$num")
            ISSUE_TITLES+=("$title")
            ISSUE_BODIES+=("$body")
        done < <(python3 -c "
import json, sys
data = json.load(sys.stdin)
for issue in data:
    num = str(issue.get('number', ''))
    title = issue.get('title', '').replace('\t', ' ').replace('\n', ' ')
    body = issue.get('body', '').replace('\t', ' ').replace('\n', ' ')
    print(f'{num}\t{title}\t{body}')
" <<< "$raw_issues" 2>/dev/null) || true
    elif command -v jq >/dev/null 2>&1; then
        while IFS=$'\t' read -r num title body; do
            ISSUE_NUMS+=("$num")
            ISSUE_TITLES+=("$title")
            ISSUE_BODIES+=("$body")
        done < <(echo "$raw_issues" | jq -r '.[] | [(.number|tostring), .title, (.body // "")] | @tsv' 2>/dev/null) || true
    fi
}

# _find_issue_ref <file> <line> — returns issue number or "untracked"
_find_issue_ref() {
    local file="$1"
    local line="$2"

    if [[ "$GH_AVAILABLE" == "false" || ${#ISSUE_NUMS[@]} -eq 0 ]]; then
        echo "untracked"
        return 0
    fi

    local i
    for (( i=0; i<${#ISSUE_NUMS[@]}; i++ )); do
        local body="${ISSUE_BODIES[$i]:-}"
        local title="${ISSUE_TITLES[$i]:-}"
        # Check if the file path appears in the issue title or body
        if echo "$body $title" | grep -qF "$file"; then
            echo "#${ISSUE_NUMS[$i]}"
            return 0
        fi
        # Also check file:line reference (e.g., "src/foo.sh:42")
        if echo "$body $title" | grep -qF "${file}:${line}"; then
            echo "#${ISSUE_NUMS[$i]}"
            return 0
        fi
    done

    echo "untracked"
}

# =============================================================================
# Output: table format
#
# Renders a markdown table:
# | File | Line | Type | Text | Issue |
# =============================================================================
_output_table() {
    local -a files=("${!1}")
    local -a lines=("${!2}")
    local -a types=("${!3}")
    local -a texts=("${!4}")
    local -a refs=("${!5}")

    echo "| File | Line | Type | Text | Issue |"
    echo "|------|------|------|------|-------|"

    local i
    for (( i=0; i<${#files[@]}; i++ )); do
        local file="${files[$i]}"
        local line="${lines[$i]}"
        local type="${types[$i]}"
        local text="${texts[$i]}"
        local ref="${refs[$i]}"
        printf "| %s | %s | %s | %s | %s |\n" "$file" "$line" "$type" "$text" "$ref"
    done
}

# =============================================================================
# Output: JSON format
#
# Renders a JSON array of {file, line, type, text, issue_ref} objects
# =============================================================================
_output_json() {
    local -a files=("${!1}")
    local -a lines=("${!2}")
    local -a types=("${!3}")
    local -a texts=("${!4}")
    local -a refs=("${!5}")

    echo "["
    local i
    local count=${#files[@]}
    for (( i=0; i<count; i++ )); do
        local file="${files[$i]}"
        local line="${lines[$i]}"
        local type="${types[$i]}"
        local text="${texts[$i]}"
        local ref="${refs[$i]}"

        # Escape for JSON: replace backslash, then double-quote
        local esc_file esc_text esc_type esc_ref
        esc_file=$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g')
        esc_text=$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g')
        esc_type=$(printf '%s' "$type" | sed 's/\\/\\\\/g; s/"/\\"/g')
        esc_ref=$(printf '%s' "$ref" | sed 's/\\/\\\\/g; s/"/\\"/g')

        local comma=""
        if [[ $(( i + 1 )) -lt $count ]]; then
            comma=","
        fi

        printf '  {"file": "%s", "line": %s, "type": "%s", "text": "%s", "issue_ref": "%s"}%s\n' \
            "$esc_file" "$line" "$esc_type" "$esc_text" "$esc_ref" "$comma"
    done
    echo "]"
}

# =============================================================================
# Main
# =============================================================================

# Step 1: Run scan
RAW_OUTPUT=$(_run_scan)

if [[ -z "$RAW_OUTPUT" ]]; then
    if [[ "$FORMAT" == "json" ]]; then
        echo "[]"
    fi
    exit 1
fi

# Step 2: Load existing issues for correlation (best-effort)
_load_issues

# Step 3: Parse scan results into parallel arrays
declare -a OUT_FILES=()
declare -a OUT_LINES=()
declare -a OUT_TYPES=()
declare -a OUT_TEXTS=()
declare -a OUT_REFS=()

while IFS= read -r raw_line; do
    [[ -z "$raw_line" ]] && continue

    # Parse the match line into components
    parsed=$(_parse_match_line "$raw_line")
    IFS=$'\t' read -r rel_file line_num marker_type marker_text <<< "$parsed"

    # Skip if marker type extraction failed (shouldn't happen but be safe)
    [[ -z "$marker_type" ]] && continue

    # Correlate with issues
    issue_ref=$(_find_issue_ref "$rel_file" "$line_num")

    OUT_FILES+=("$rel_file")
    OUT_LINES+=("$line_num")
    OUT_TYPES+=("$marker_type")
    OUT_TEXTS+=("$marker_text")
    OUT_REFS+=("$issue_ref")
done <<< "$RAW_OUTPUT"

if [[ ${#OUT_FILES[@]} -eq 0 ]]; then
    if [[ "$FORMAT" == "json" ]]; then
        echo "[]"
    fi
    exit 1
fi

# Step 4: Output
if [[ "$FORMAT" == "json" ]]; then
    _output_json OUT_FILES[@] OUT_LINES[@] OUT_TYPES[@] OUT_TEXTS[@] OUT_REFS[@]
else
    _output_table OUT_FILES[@] OUT_LINES[@] OUT_TYPES[@] OUT_TEXTS[@] OUT_REFS[@]
fi

exit 0
