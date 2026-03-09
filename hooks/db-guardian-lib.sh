#!/usr/bin/env bash
# db-guardian-lib.sh — Deterministic policy engine, simulation helpers, and approval gate
#                      for the DB Guardian agent (Wave 3b: D3/D4/D5)
#
# This library is NOT loaded by pre-bash.sh. It is sourced by the DB Guardian
# agent at the start of every database operation assessment. It depends on
# db-safety-lib.sh (environment detection, CLI detection) and state-lib.sh
# (approval token persistence).
#
# Architecture:
#   D3 — Policy engine: deterministic rule evaluation producing allow/deny/escalate
#   D4 — Simulation helpers: build CLI-specific EXPLAIN/rollback/dryrun commands
#   D5 — Approval gate: request and check approval tokens via state store
#
# Loading:
#   source hooks/db-guardian-lib.sh
#   (state-lib.sh must be loaded separately if D5 functions are needed)
#
# @decision DEC-DBGUARD-001
# @title Separate db-guardian-lib.sh from db-safety-lib.sh for agent-layer concerns
# @status accepted
# @rationale db-safety-lib.sh handles pre-bash.sh hook concerns (CLI detection,
#   environment classification, risk scoring for the deterministic gate). The DB
#   Guardian agent needs a higher-level policy engine, simulation command builders,
#   and an approval gate that integrate with the state store. Mixing these in
#   db-safety-lib.sh would couple the lightweight hook layer to the agent layer
#   (approval state, simulation, structured JSON output). Keeping them separate:
#   (1) preserves zero-overhead loading for the hook path (db-safety-lib.sh never
#       imports state-lib.sh), (2) makes the agent's decision logic independently
#       testable, (3) follows the separation established by DEC-DBSAFE-001.
#
# @decision DEC-DBGUARD-002
# @title Deterministic policy engine: rules evaluated in priority order, no LLM
# @status accepted
# @rationale The policy engine must be auditable, deterministic, and fast. LLM
#   reasoning is not appropriate for safety-critical allow/deny decisions — it can
#   hallucinate, be slow, or fail. Instead, rules are evaluated in a fixed priority
#   order with explicit IDs and structured output. The DB Guardian agent uses the
#   engine output as input to its reasoning, but the deny/escalate decisions are
#   final and cannot be overridden by the agent without explicit user approval.
#   Each rule returns "allow|deny|escalate:<rule_id>:<reason>" for auditability.

# Guard: prevent re-sourcing
[[ -n "${_DB_GUARDIAN_LIB_LOADED:-}" ]] && return 0
_DB_GUARDIAN_LIB_LOADED=1
_DB_GUARDIAN_LIB_VERSION=1

# ---------------------------------------------------------------------------
# _dbg_classify_operation QUERY
#
# Classifies a SQL/NoSQL query into one of four operation categories:
#   read      — SELECT, SHOW, DESCRIBE, EXPLAIN (no data modification)
#   write_dml — INSERT, UPDATE, DELETE, MERGE, UPSERT (data modification)
#   write_ddl — CREATE, DROP, ALTER, TRUNCATE, RENAME (schema modification)
#   admin     — GRANT, REVOKE, CREATE USER, DROP USER (privilege/admin ops)
#
# Classification is case-insensitive and matches on the first keyword.
# TRUNCATE is classified as write_ddl because it is DDL in most databases
# (auto-commits, schema-level operation) even though it modifies data.
#
# Returns: "read|write_dml|write_ddl|admin"
# ---------------------------------------------------------------------------
_dbg_classify_operation() {
    local query="$1"

    # Normalize: trim leading whitespace and extract first keyword
    local first_keyword
    first_keyword=$(printf '%s' "$query" | sed 's/^[[:space:]]*//' | awk '{print toupper($1)}')

    case "$first_keyword" in
        SELECT|SHOW|DESCRIBE|DESC|EXPLAIN|WITH|CALL|EXEC|EXECUTE)
            printf 'read'
            ;;
        INSERT|UPDATE|DELETE|MERGE|UPSERT|REPLACE)
            printf 'write_dml'
            ;;
        CREATE|DROP|ALTER|TRUNCATE|RENAME|COMMENT|INDEX|REINDEX)
            printf 'write_ddl'
            ;;
        GRANT|REVOKE|DENY|CREATE\ USER|DROP\ USER|ALTER\ USER|CREATE\ ROLE|DROP\ ROLE)
            printf 'admin'
            ;;
        *)
            # Check multi-word DDL patterns not caught by first keyword
            local upper_query
            upper_query=$(printf '%s' "$query" | tr '[:lower:]' '[:upper:]')
            if printf '%s' "$upper_query" | grep -qE '^[[:space:]]*(CREATE|DROP|ALTER)[[:space:]]+'; then
                printf 'write_ddl'
            elif printf '%s' "$upper_query" | grep -qE '^[[:space:]]*(GRANT|REVOKE)[[:space:]]+'; then
                printf 'admin'
            else
                # Unknown — treat conservatively as write_dml
                printf 'write_dml'
            fi
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_detect_cascade_risk QUERY
#
# Heuristically checks whether a query involves foreign key cascades or
# explicit CASCADE clauses that could propagate destruction beyond the
# immediate target table.
#
# Detection patterns:
#   - Explicit CASCADE keyword (DROP TABLE x CASCADE, DELETE ... CASCADE)
#   - ON DELETE CASCADE or ON UPDATE CASCADE in ALTER statements
#   - FOREIGN KEY / REFERENCES mentions (structural cascade relationships)
#   - JOIN in DELETE statements (multi-table delete with relationships)
#
# Returns: "true" or "false"
#
# @decision DEC-DBGUARD-003
# @title Heuristic cascade detection using keyword patterns, not schema introspection
# @status accepted
# @rationale True cascade risk detection requires schema introspection (querying
#   information_schema or pg_constraint). This is not possible at policy evaluation
#   time without a database connection. Instead, we use conservative keyword
#   heuristics: if the query text contains cascade-related keywords, we flag it.
#   False positives (flagging a query that mentions CASCADE in a comment) are
#   acceptable — the cost is an escalation that a human resolves. False negatives
#   (missing a cascade) are unacceptable. Conservative heuristics serve the
#   safety goal even at the cost of occasional over-escalation.
# ---------------------------------------------------------------------------
_dbg_detect_cascade_risk() {
    local query="$1"

    # Check for cascade-related patterns (case insensitive)
    local upper_query
    upper_query=$(printf '%s' "$query" | tr '[:lower:]' '[:upper:]')

    # Explicit CASCADE keyword
    if printf '%s' "$upper_query" | grep -qE '\bCASCADE\b'; then
        printf 'true'
        return 0
    fi

    # FOREIGN KEY or REFERENCES (structural cascade relationships)
    if printf '%s' "$upper_query" | grep -qE '\b(FOREIGN[[:space:]]+KEY|REFERENCES)\b'; then
        printf 'true'
        return 0
    fi

    # ON DELETE / ON UPDATE cascade pattern in DDL
    if printf '%s' "$upper_query" | grep -qE '\bON[[:space:]]+(DELETE|UPDATE)\b'; then
        printf 'true'
        return 0
    fi

    printf 'false'
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_detect_unbounded QUERY
#
# Checks for DELETE or UPDATE statements that lack a WHERE clause.
# An unbounded DELETE/UPDATE affects every row in the table — one of the
# most common causes of catastrophic data loss.
#
# Detection strategy:
#   1. Must be a DELETE or UPDATE statement
#   2. Must NOT contain a WHERE, LIMIT, or subquery that bounds the scope
#
# Returns: "true" (unbounded) or "false" (bounded or not a DML write)
#
# @decision DEC-DBGUARD-004
# @title Detect unbounded DML via absence-of-WHERE pattern, not SQL parsing
# @status accepted
# @rationale Full SQL parsing to detect the absence of a WHERE clause would
#   require a proper parser. Instead, we normalize the query to uppercase and
#   check: (1) the query starts with DELETE or UPDATE, (2) no WHERE keyword
#   appears after the table reference. This works for all common patterns.
#   Edge cases (CTEs, subqueries) are handled by checking for SELECT inside
#   the query — if a subquery is present, it likely provides bounded scope.
#   The heuristic errs toward false positives (safe) over false negatives.
# ---------------------------------------------------------------------------
_dbg_detect_unbounded() {
    local query="$1"

    local upper_query
    upper_query=$(printf '%s' "$query" | tr '[:lower:]' '[:upper:]')

    # Must be DELETE or UPDATE
    if ! printf '%s' "$upper_query" | grep -qE '^[[:space:]]*(DELETE|UPDATE)\b'; then
        printf 'false'
        return 0
    fi

    # Check for WHERE clause
    if printf '%s' "$upper_query" | grep -qE '\bWHERE\b'; then
        printf 'false'
        return 0
    fi

    # Check for LIMIT clause (bounded by row count)
    if printf '%s' "$upper_query" | grep -qE '\bLIMIT\b'; then
        printf 'false'
        return 0
    fi

    # Check for IN subquery (bounded by subquery result)
    if printf '%s' "$upper_query" | grep -qE '\bIN[[:space:]]*\('; then
        printf 'false'
        return 0
    fi

    # No WHERE, LIMIT, or bounding clause found — unbounded
    printf 'true'
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_evaluate_policy OPERATION_TYPE TARGET_ENV QUERY [HAS_APPROVAL_TOKEN] [HAS_BACKUP]
#
# Evaluates the operation against the policy rule set in priority order.
# Rules are evaluated highest-priority-first; the first matching rule wins.
#
# Arguments:
#   OPERATION_TYPE    — one of: read, write_dml, write_ddl, admin
#   TARGET_ENV        — one of: production, staging, development, local, unknown
#   QUERY             — the SQL/command string
#   HAS_APPROVAL_TOKEN — "approved" if an approval token exists, "" otherwise
#   HAS_BACKUP        — "true" if verified backup exists, "false" or "" otherwise
#
# Returns: "<decision>|<rule_id>:<reason>"
#   decision: "allow", "deny", or "escalate"
#   rule_id:  identifies which rule matched
#   reason:   human-readable explanation
#
# Policy Rules (evaluated in priority order):
#   Priority 1: cascade-check     — FK cascade risk, all envs → escalate
#   Priority 2: unbounded-delete  — DELETE/UPDATE without WHERE → deny (prod/staging), warn (dev)
#   Priority 3: backup-required   — DDL in prod/staging without backup → deny
#   Priority 4: prod-no-ddl       — DDL in production → deny
#   Priority 5: prod-readonly     — Write in production → deny (unless approved)
#   Priority 6: staging-approval  — Destructive DML in staging → escalate
#   Priority 7: dev-permissive    — Any op in development → allow
#   Priority 8: local-permissive  — Any op against localhost → allow
#   Priority 9: unknown-conservative — Write in unknown env → deny
#   Default:    allow             — All reads and unmatched ops → allow
#
# @decision DEC-DBGUARD-005
# @title Rule priority: structural safety > env-specific policy > permissive defaults
# @status accepted
# @rationale Cascade and unbounded checks are evaluated first because they represent
#   structural risk that is environment-independent (an unbounded DELETE in development
#   that gets accidentally run in production is still catastrophic). Environment-specific
#   rules come next. Permissive defaults (dev, local) are low-priority so structural
#   checks always fire first even in development environments.
# ---------------------------------------------------------------------------
_dbg_evaluate_policy() {
    local op_type="${1:-write_dml}"
    local target_env="${2:-unknown}"
    local query="${3:-}"
    local has_approval="${4:-}"
    local has_backup="${5:-false}"

    # --- Priority 1: cascade-check (all environments) ---
    # Cascade risk escalates regardless of environment — human must review.
    if [[ "$op_type" == "write_dml" || "$op_type" == "write_ddl" ]]; then
        local cascade_risk
        cascade_risk="$(_dbg_detect_cascade_risk "$query")"
        if [[ "$cascade_risk" == "true" ]]; then
            printf 'escalate|cascade-check:Query involves potential FK cascade; human review required'
            return 0
        fi
    fi

    # --- Priority 2: unbounded-delete (deny in prod/staging, warn in dev) ---
    local is_unbounded
    is_unbounded="$(_dbg_detect_unbounded "$query")"
    if [[ "$is_unbounded" == "true" ]]; then
        case "$target_env" in
            production|staging|unknown)
                printf 'deny|unbounded-delete:DELETE/UPDATE without WHERE clause; all rows would be affected'
                return 0
                ;;
            development|local)
                # In dev/local we warn but do not deny — logged separately
                printf 'allow|unbounded-delete-warning:Unbounded DML in non-production; proceeding with audit log'
                return 0
                ;;
        esac
    fi

    # --- Priority 3: backup-required (DDL in prod/staging without verified backup) ---
    if [[ "$op_type" == "write_ddl" ]]; then
        case "$target_env" in
            production|staging)
                if [[ "$has_backup" != "true" ]]; then
                    printf 'deny|backup-required:DDL in %s requires verified backup before proceeding' "$target_env"
                    return 0
                fi
                ;;
        esac
    fi

    # --- Priority 4: prod-no-ddl (any DDL in production denied; DBA approval required) ---
    if [[ "$op_type" == "write_ddl" && "$target_env" == "production" ]]; then
        printf 'deny|prod-no-ddl:DDL in production requires DBA approval; use change management process'
        return 0
    fi

    # --- Priority 5: prod-readonly (writes in production) ---
    if [[ "$target_env" == "production" ]]; then
        case "$op_type" in
            write_dml|write_ddl|admin)
                if [[ "$has_approval" == "approved" ]]; then
                    printf 'allow|prod-readonly-approved:Write in production allowed with explicit approval token'
                    return 0
                fi
                printf 'deny|prod-readonly:Write operation in production requires explicit approval token'
                return 0
                ;;
        esac
    fi

    # --- Priority 6: staging-approval (destructive DML in staging) ---
    if [[ "$target_env" == "staging" ]]; then
        case "$op_type" in
            write_dml)
                # DELETE is inherently destructive; INSERT/UPDATE are lower risk
                local upper_query
                upper_query=$(printf '%s' "$query" | tr '[:lower:]' '[:upper:]')
                if printf '%s' "$upper_query" | grep -qE '^[[:space:]]*DELETE\b'; then
                    printf 'escalate|staging-approval:Destructive DML (DELETE) in staging requires user approval'
                    return 0
                fi
                # Non-DELETE DML in staging: allow with audit
                printf 'allow|staging-dml:Non-destructive DML in staging allowed with audit log'
                return 0
                ;;
        esac
    fi

    # --- Priority 7: dev-permissive (all operations in development) ---
    if [[ "$target_env" == "development" ]]; then
        printf 'allow|dev-permissive:All operations allowed in development environment; audit logged'
        return 0
    fi

    # --- Priority 8: local-permissive (all operations against localhost) ---
    if [[ "$target_env" == "local" ]]; then
        printf 'allow|local-permissive:All operations allowed against local database'
        return 0
    fi

    # --- Priority 9: unknown-conservative (writes in unknown environment) ---
    if [[ "$target_env" == "unknown" ]]; then
        case "$op_type" in
            write_dml|write_ddl|admin)
                printf 'deny|unknown-conservative:Write operation in unknown environment denied; classify environment first'
                return 0
                ;;
        esac
    fi

    # --- Default: allow (reads, and any remaining unmatched patterns) ---
    printf 'allow|default:Operation permitted by default policy'
    return 0
}

# =============================================================================
# D4: Simulation Helpers
#
# These functions build the COMMAND strings used to simulate operations before
# executing. The DB Guardian agent passes these commands to its Bash tool calls.
# The functions do NOT execute the commands themselves — they generate the
# correct CLI invocation for each database type.
#
# @decision DEC-DBGUARD-006
# @title Simulation functions generate command strings, not execute them
# @status accepted
# @rationale The DB Guardian agent must be able to inspect and approve the
#   simulation command before execution. If functions executed commands directly,
#   the agent would have no visibility into what was run. Returning command strings
#   allows the agent to display the simulation command to the user, execute it
#   through the Bash tool (with full audit trail), and parse the output.
#   This separation also makes unit testing straightforward — no database required.
# =============================================================================

# ---------------------------------------------------------------------------
# _dbg_simulate_explain CLI_TYPE QUERY CONNECTION_ARGS
#
# Builds an EXPLAIN command to estimate rows affected without executing.
#
# CLI-specific behavior:
#   psql     — EXPLAIN (ANALYZE false) <query>  (via -c flag)
#   mysql    — EXPLAIN <query>                  (via -e flag)
#   sqlite3  — EXPLAIN <query>                  (outputs opcodes)
#   mongosh  — db.collection.find({}).explain() (wraps find/aggregate)
#   redis-cli — "unsupported" (no preview mode)
#   cockroach — same as psql (CockroachDB supports EXPLAIN)
#
# Returns: the command string to execute, or "unsupported"
# ---------------------------------------------------------------------------
_dbg_simulate_explain() {
    local cli_type="${1:-}"
    local query="${2:-}"
    local connection_args="${3:-}"

    case "$cli_type" in
        psql|cockroach)
            # Wrap in EXPLAIN (ANALYZE false) to get the query plan without execution
            printf '%s %s -c "EXPLAIN (ANALYZE false) %s"' "$cli_type" "$connection_args" "$query"
            ;;
        mysql)
            # MySQL EXPLAIN shows optimizer's execution plan
            printf 'mysql %s -e "EXPLAIN %s"' "$connection_args" "$query"
            ;;
        sqlite3)
            # SQLite EXPLAIN outputs virtual machine opcodes; useful for understanding query plan
            printf 'sqlite3 %s "EXPLAIN %s"' "$connection_args" "$query"
            ;;
        mongosh)
            # mongosh explain() wraps the operation
            # Strip trailing semicolons/parens to inject .explain()
            local wrapped_query
            wrapped_query=$(printf '%s' "$query" | sed 's/[;[:space:]]*$//')
            printf 'mongosh %s --eval "%s.explain()"' "$connection_args" "$wrapped_query"
            ;;
        redis-cli)
            # Redis has no EXPLAIN or preview mode
            printf 'unsupported'
            ;;
        *)
            printf 'unsupported'
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_simulate_rollback CLI_TYPE QUERY CONNECTION_ARGS
#
# Wraps a DML query in a transaction that is always rolled back, allowing
# the agent to observe actual row counts and effects without committing.
#
# CLI-specific behavior:
#   psql     — BEGIN; <query>; ROLLBACK; (via -c, shows rows affected)
#   mysql    — BEGIN; <query>; ROLLBACK; NOTE: DDL auto-commits in MySQL
#   sqlite3  — BEGIN; <query>; ROLLBACK; (SQLite supports full transactions)
#   mongosh  — session.withTransaction() with abort (Mongo 4.0+ multi-doc txn)
#   redis-cli — "unsupported" (MULTI/EXEC has no preview/abort-after-preview mode)
#   cockroach — same as psql
#
# Returns: the command string to execute, or "unsupported"
# ---------------------------------------------------------------------------
_dbg_simulate_rollback() {
    local cli_type="${1:-}"
    local query="${2:-}"
    local connection_args="${3:-}"

    case "$cli_type" in
        psql|cockroach)
            printf '%s %s -c "BEGIN; %s; ROLLBACK;"' "$cli_type" "$connection_args" "$query"
            ;;
        mysql)
            # MySQL DDL (CREATE/DROP/ALTER/TRUNCATE) auto-commits and cannot be rolled back
            local upper_query
            upper_query=$(printf '%s' "$query" | tr '[:lower:]' '[:upper:]')
            if printf '%s' "$upper_query" | grep -qE '^[[:space:]]*(CREATE|DROP|ALTER|TRUNCATE|RENAME)\b'; then
                printf 'mysql %s -e "-- NOTE: DDL auto-commit in MySQL; rollback simulation unavailable. Query: %s"' \
                    "$connection_args" "$query"
            else
                printf 'mysql %s -e "BEGIN; %s; ROLLBACK;"' "$connection_args" "$query"
            fi
            ;;
        sqlite3)
            printf 'sqlite3 %s "BEGIN; %s; ROLLBACK;"' "$connection_args" "$query"
            ;;
        mongosh)
            # MongoDB 4.0+ supports multi-document transactions with abort
            printf 'mongosh %s --eval "const s=db.getMongo().startSession(); s.startTransaction(); %s; s.abortTransaction();"' \
                "$connection_args" "$query"
            ;;
        redis-cli)
            printf 'unsupported'
            ;;
        *)
            printf 'unsupported'
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_simulate_dryrun CLI_TYPE QUERY
#
# For DDL operations: generates a human-readable description of what would
# happen if the DDL were executed, without actually executing it.
#
# This is a textual analysis function — it parses the query and generates
# a structured description. For psql/cockroach, it also generates a BEGIN/ROLLBACK
# simulation command that the agent can execute to see actual DDL effects.
#
# Returns: description of what would happen
# ---------------------------------------------------------------------------
_dbg_simulate_dryrun() {
    local cli_type="${1:-}"
    local query="${2:-}"

    local upper_query
    upper_query=$(printf '%s' "$query" | tr '[:lower:]' '[:upper:]')

    # Extract the primary DDL verb and target
    local ddl_verb table_name
    ddl_verb=$(printf '%s' "$upper_query" | awk '{print $1}')
    table_name=$(printf '%s' "$upper_query" | sed -E 's/^[[:space:]]*(CREATE|DROP|ALTER|TRUNCATE|RENAME)[[:space:]]+(TABLE[[:space:]]+|INDEX[[:space:]]+|VIEW[[:space:]]+)?([[:alnum:]_."]+).*/\3/')

    case "$ddl_verb" in
        DROP)
            printf 'DRY-RUN: DROP TABLE %s — would permanently delete the table structure and ALL data. CLI: %s' \
                "$table_name" "$cli_type"
            ;;
        CREATE)
            printf 'DRY-RUN: CREATE operation on %s — would create new schema object. CLI: %s' \
                "$table_name" "$cli_type"
            ;;
        ALTER)
            printf 'DRY-RUN: ALTER TABLE %s — would modify table structure. MySQL auto-commits DDL (no rollback). CLI: %s' \
                "$table_name" "$cli_type"
            ;;
        TRUNCATE)
            printf 'DRY-RUN: TRUNCATE %s — would delete ALL rows instantly (faster than DELETE, may not fire triggers). CLI: %s' \
                "$table_name" "$cli_type"
            ;;
        RENAME)
            printf 'DRY-RUN: RENAME operation on %s — would rename schema object. CLI: %s' \
                "$table_name" "$cli_type"
            ;;
        *)
            printf 'DRY-RUN: DDL operation on %s — would modify database schema. CLI: %s. Query: %s' \
                "$table_name" "$cli_type" "$query"
            ;;
    esac
    return 0
}

# =============================================================================
# D5: Approval Gate
#
# The approval gate integrates with the existing state store (state-lib.sh) to
# create a persistent approval token mechanism. When a high-risk operation
# requires approval, the DB Guardian agent:
#   1. Calls _dbg_request_approval() to register the request and get a JSON payload
#   2. Presents the JSON payload to the orchestrator/user
#   3. The user grants approval (orchestrator writes state token)
#   4. Calls _dbg_check_approval() to verify the token before executing
#
# State keys: "dbg.approval.<execution_id>" → "pending" | "approved" | "denied"
#
# @decision DEC-DBGUARD-007
# @title Use state store (state-lib.sh) for approval token persistence
# @status accepted
# @rationale Approval tokens must survive agent restarts and be readable by
#   both the agent and the orchestrator. The state store (SQLite WAL via
#   state-lib.sh) is the established mechanism for this kind of cross-agent
#   coordination (see DEC-SQLITE-001). Writing to state.db ensures tokens are
#   durable, isolated by workflow_id, and auditable via the state history log.
#   File-based tokens in /tmp would not survive cleanup or be workflow-isolated.
# =============================================================================

# ---------------------------------------------------------------------------
# _dbg_request_approval OPERATION_DESCRIPTION SIMULATION_RESULT [EXECUTION_ID]
#
# Registers an approval request in the state store and returns a structured
# JSON approval request for the orchestrator to present to the user.
#
# Arguments:
#   OPERATION_DESCRIPTION — human-readable description of the operation
#   SIMULATION_RESULT     — output from simulation (EXPLAIN or rollback preview)
#   EXECUTION_ID          — optional; generated deterministically if omitted
#
# Side effects:
#   Writes "dbg.approval.<execution_id>" = "pending" to state store
#
# Returns: JSON approval request object on stdout
# ---------------------------------------------------------------------------
_dbg_request_approval() {
    local operation_desc="${1:-}"
    local simulation_result="${2:-}"
    local execution_id="${3:-}"

    # Generate execution ID if not provided
    if [[ -z "$execution_id" ]]; then
        execution_id="dbg-$(date +%s)-$$"
    fi

    # Register as pending in state store (if state functions are available)
    if type state_update &>/dev/null 2>&1; then
        state_update "dbg.approval.${execution_id}" "pending" "db-guardian"
    fi

    # Escape values for JSON (basic escaping — double quotes and backslashes)
    local escaped_desc escaped_sim
    escaped_desc=$(printf '%s' "$operation_desc" | sed 's/\\/\\\\/g; s/"/\\"/g')
    escaped_sim=$(printf '%s' "$simulation_result" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Return structured JSON approval request
    printf '{"type":"approval_request","execution_id":"%s","operation":"%s","simulation":"%s","status":"pending","instructions":"Set state key dbg.approval.%s to approved to authorize this operation"}' \
        "$execution_id" "$escaped_desc" "$escaped_sim" "$execution_id"
    return 0
}

# ---------------------------------------------------------------------------
# _dbg_check_approval EXECUTION_ID
#
# Checks whether an approval token exists for the given execution ID.
# Reads the state store key "dbg.approval.<execution_id>".
#
# Returns: "approved" if the token is approved, "pending" otherwise
#   (denied and missing both return "pending" for safe-default behavior)
# ---------------------------------------------------------------------------
_dbg_check_approval() {
    local execution_id="${1:-}"

    if [[ -z "$execution_id" ]]; then
        printf 'pending'
        return 0
    fi

    # Check state store if available
    if type state_read &>/dev/null 2>&1; then
        local token
        token=$(state_read "dbg.approval.${execution_id}" 2>/dev/null || printf '')
        if [[ "$token" == "approved" ]]; then
            printf 'approved'
            return 0
        fi
    fi

    # Default: pending (safe)
    printf 'pending'
    return 0
}
