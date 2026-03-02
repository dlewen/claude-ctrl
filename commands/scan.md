---
name: scan
description: Scan codebase for debt markers (TODO, FIXME, HACK, etc.) and correlate with GitHub issues. Usage: /scan [--json | --create | <path>]
argument-hint: "[--json | --create | <path>]"
---

# /scan — Codebase Debt Marker Scanner

Scan the current project for debt markers and surface untracked technical debt.

**Markers scanned:** `TODO`, `FIXME`, `HACK`, `XXX`, `OPTIMIZE`, `TEMP`, `WORKAROUND`

**Backed by:** `scripts/scan-backlog.sh` — rg/grep scanner with gh issue correlation.

## Instructions

Parse `$ARGUMENTS` to determine flags and target:

### Argument parsing

- **No arguments:** Scan current project root (default table format)
- **`--json`:** Raw JSON output instead of table
- **`--create`:** Auto-create GitHub issues for untracked markers
- **`<path>`:** Scan specific directory (can be combined with other flags)

Multiple flags may be combined, e.g. `/scan --create ./src`.

### Step 1: Locate the scan script

```bash
SCAN_SCRIPT="$HOME/.claude/scripts/scan-backlog.sh"
TODO_SCRIPT="$HOME/.claude/scripts/todo.sh"
```

If `$SCAN_SCRIPT` does not exist, inform the user:
> "The scan-backlog.sh script was not found at `~/.claude/scripts/scan-backlog.sh`. Please ensure Phase 2 of the backlog-scanner feature is installed."

### Step 2: Parse $ARGUMENTS

```bash
ARGS="$ARGUMENTS"
USE_JSON=false
USE_CREATE=false
SCAN_PATH=""

for arg in $ARGS; do
    case "$arg" in
        --json)   USE_JSON=true ;;
        --create) USE_CREATE=true ;;
        *)        SCAN_PATH="$arg" ;;
    esac
done
```

### Step 3: Run the scanner

Build the command and run it:

```bash
CMD="$SCAN_SCRIPT"
[[ "$USE_JSON" == "true" ]] && CMD="$CMD --format json"
[[ -n "$SCAN_PATH" ]] && CMD="$CMD $SCAN_PATH"
```

Capture output and exit code:

```bash
SCAN_OUTPUT=$(bash $CMD 2>&1)
SCAN_EXIT=$?
```

Exit code semantics:
- `0` — markers found, display output
- `1` — no markers found, show "No debt markers found" message
- `2` — error (bad path, bad args), show error and stop

### Step 4: Display results

**If `--json` flag:** Display the raw JSON output in a code block.

**If table format (default):** Display the markdown table directly. The table has columns: `File`, `Line`, `Type`, `Text`, `Issue`.

After the table, show a summary line:

```
Found N markers: M tracked, K untracked
```

Where:
- `N` = total markers in the table
- `M` = rows where Issue column is not "untracked"
- `K` = rows where Issue column is "untracked"

### Step 5: Auto-create issues (--create flag only)

For each untracked marker (Issue = "untracked"), create a GitHub issue:

```bash
bash "$TODO_SCRIPT" create "TYPE: text" \
    --body "File: file:line" \
    --context "scan:auto-created"
```

Where:
- `TYPE` = the marker type (TODO, FIXME, etc.)
- `text` = the marker text content
- `file:line` = the relative file path and line number

After creating all issues, show a summary:
> "Created K issues for untracked markers."

If `gh` is not available, skip creation and note:
> "Cannot create issues: `gh` CLI not found. Install GitHub CLI to use --create."

### Example outputs

**Default scan (no markers):**
```
No debt markers found in current project.
```

**Default scan (markers found):**
```
| File | Line | Type | Text | Issue |
|------|------|------|------|-------|
| src/auth.sh | 42 | TODO | fix token refresh logic | untracked |
| hooks/pre-write.sh | 18 | HACK | works around gh API timeout | #15 |

Found 2 markers: 1 tracked, 1 untracked.
```

**With --create:**
```
| File | Line | Type | Text | Issue |
|------|------|------|------|-------|
| src/auth.sh | 42 | TODO | fix token refresh logic | untracked |

Found 1 marker: 0 tracked, 1 untracked.

Creating issue for untracked marker...
Created 1 issue for untracked markers.
```

**With --json:**
```json
[
  {"file": "src/auth.sh", "line": 42, "type": "TODO", "text": "fix token refresh logic", "issue_ref": "untracked"}
]
```

## Notes

- Issue correlation is best-effort (searches issue body/title for the file path).
- Binary files, vendor directories, and .git are automatically excluded.
- The scanner respects `.gitignore` when `rg` is available; falls back to `grep -r` otherwise.
- With `--create`, issues are filed in the current project repo (or global `cc-todos` repo if not in a GitHub repo).
