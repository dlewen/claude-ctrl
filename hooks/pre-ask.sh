#!/usr/bin/env bash
# PreToolUse:AskUserQuestion — merit gate for user interruptions.
#
# Fires before every AskUserQuestion call. Classifies the question text
# and denies anti-patterns that waste user attention.
#
# Gates enforced:
#   1. forward-motion-deny  — blocks "should we continue?" style questions from subagents
#   2. duplicate-gate-deny  — blocks "should I commit/merge/push?" pre-asks from subagents
#   3. obvious-answer-deny  — blocks questions where one option is already Recommended (≤2 options)
#   4. agent-context-advisory — reminds implementers to check the plan before escalating
#
# Always-allow bypasses:
#   - Orchestrator context (no active agent marker)
#   - Tester env-var asks (environment variable not set)
#
# @decision DEC-ASK-GATE-001
# @title Pre-ask merit gate with 4 classification gates
# @status accepted
# @rationale AskUserQuestion is expensive — it interrupts the user and breaks flow.
#   Forward-motion questions ("should I continue?") violate auto-dispatch rules that
#   prescribe the next step. Duplicate-gate questions ("should I commit?") duplicate
#   Guardian's approval cycle. Obvious-answer questions ("which approach? (Recommended)")
#   with ≤2 options add no value. The gate enforces these rules mechanically so agents
#   don't accidentally waste user attention. Scoped to subagents only — the orchestrator
#   must retain full AskUserQuestion access for legitimate disambiguation.

set -euo pipefail

_HOOK_NAME="pre-ask"
_HOOK_EVENT_TYPE="PreToolUse:AskUserQuestion"

source "$(dirname "$0")/source-lib.sh"

enable_fail_closed "pre-ask"

# In scan mode: emit all gate declarations and exit cleanly.
if [[ "${HOOK_GATE_SCAN:-}" == "1" ]]; then
    declare_gate "forward-motion-deny" "Blocks forward-motion questions from subagents (should we continue?)" "deny"
    declare_gate "duplicate-gate-deny" "Blocks commit/merge/push pre-asks from subagents" "deny"
    declare_gate "obvious-answer-deny" "Blocks questions with a Recommended option and ≤2 choices" "deny"
    declare_gate "agent-context-advisory" "Reminds implementers to check the plan before escalating" "advisory"
    emit_flush
    exit 0
fi

HOOK_INPUT=$(read_input)

# Enable case-insensitive regex matching for all gate pattern checks.
# AskUserQuestion text may be capitalized ("Should we..." vs "should we...").
shopt -s nocasematch

# --- Agent context detection ---
# Reads .active-{type}-*-{phash} markers written by trace-lib.sh init_trace().
# Returns the active agent type ("implementer", "planner", "tester", "guardian",
# or "orchestrator" when no marker is found).
get_active_agent_type() {
    local trace_store="${TRACE_STORE:-$HOME/.claude/traces}"
    local project_root
    project_root=$(detect_project_root 2>/dev/null || echo "$HOME/.claude")
    local phash
    phash=$(project_hash "$project_root")
    for t in implementer planner tester guardian; do
        for m in "${trace_store}/.active-${t}-"*"-${phash}"; do
            [[ -f "$m" ]] && echo "$t" && return 0
        done
    done
    echo "orchestrator"
}

AGENT_TYPE=$(get_active_agent_type)

# --- Extract question text for regex matching ---
# Concatenates all question strings from the questions array for pattern matching.
QUESTION_TEXT=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.questions[].question // empty' 2>/dev/null | tr '\n' ' ' || echo "")

# --- Always-allow bypass: orchestrator context ---
# The orchestrator must retain full AskUserQuestion access for legitimate disambiguation.
if [[ "$AGENT_TYPE" == "orchestrator" ]]; then
    emit_flush
    exit 0
fi

# --- Always-allow bypass: tester env-var asks ---
# Testers legitimately need to ask about missing environment variables for live tests.
if [[ "$QUESTION_TEXT" =~ (environment[[:space:]]+variable|env[[:space:]]+var|not[[:space:]]+set|missing.*variable) ]]; then
    emit_flush
    exit 0
fi

# --- Gate 1: forward-motion-deny ---
# Blocks "should we continue / proceed / go ahead?" from subagents.
# These violate auto-dispatch rules — the orchestrator's dispatch prompt prescribes
# the next action; subagents must return their summary instead of asking.
declare_gate "forward-motion-deny" "Blocks forward-motion questions from subagents (should we continue?)" "deny"
if [[ "$QUESTION_TEXT" =~ (want|shall|should|can|ready).*(continue|proceed|go[[:space:]]+ahead|keep[[:space:]]+going|move[[:space:]]+on|begin|start) ]]; then
    emit_deny "Forward-motion question blocked. Auto-dispatch rules prescribe the next step — return to the orchestrator with your summary instead of asking."
fi

# --- Gate 2: duplicate-gate-deny ---
# Blocks commit/merge/push pre-asks from subagents.
# Guardian owns the full commit/merge/push approval cycle — pre-asking duplicates it.
declare_gate "duplicate-gate-deny" "Blocks commit/merge/push pre-asks from subagents" "deny"
if [[ "$QUESTION_TEXT" =~ (should|want|ok|ready).*(commit|merge|push) ]]; then
    emit_deny "Duplicate gate question blocked. Guardian owns the commit/merge/push approval cycle — return to the orchestrator instead of pre-asking."
fi

# --- Gate 3: obvious-answer-deny ---
# Blocks questions where one option is already marked "(Recommended)" and ≤2 options exist.
# With ≥3 options, the Recommended label provides useful guidance but doesn't eliminate
# the choice — allow those through.
declare_gate "obvious-answer-deny" "Blocks questions with a Recommended option and ≤2 choices" "deny"
HAS_RECOMMENDED=$(printf '%s' "$HOOK_INPUT" | jq 'any(.tool_input.questions[].options[]?.label? // "" | tostring; contains("(Recommended)") or contains("(Default)"))' 2>/dev/null || echo "false")
TOTAL_OPTIONS=$(printf '%s' "$HOOK_INPUT" | jq '[.tool_input.questions[].options[] // empty] | length' 2>/dev/null || echo "0")
if [[ "$HAS_RECOMMENDED" == "true" && "$TOTAL_OPTIONS" -le 2 ]]; then
    emit_deny "One option is already marked Recommended — use it instead of asking."
fi

# --- Gate 4: agent-context-advisory ---
# Non-blocking reminder for implementers with generic check-in questions.
# "How does this look?" / "What approach should I use?" — check the plan first.
declare_gate "agent-context-advisory" "Reminds implementers to check the plan before escalating" "advisory"
if [[ "$AGENT_TYPE" == "implementer" ]]; then
    if [[ "$QUESTION_TEXT" =~ (how|what).*(look|think|approach) ]]; then
        emit_advisory "Check the plan before escalating to the user."
    fi
fi

emit_flush
exit 0
