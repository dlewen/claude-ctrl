#!/usr/bin/env bash
# scripts/claude-sandbox.sh — External bwrap sandbox wrapper for Claude Code
#
# Launches Claude Code inside a bubblewrap (bwrap) OS-level sandbox.
# Provides filesystem isolation without relying on Claude Code's built-in
# sandbox, which is broken on Ubuntu systems with AppArmor user namespace
# restrictions (kernel.apparmor_restrict_unprivileged_userns=1).
#
# Usage:
#   claude-sandbox.sh [PROJECT_DIR] [-- extra-claude-args...]
#   claude-sandbox.sh --help
#
# @decision DEC-SANDBOX-WRAPPER-001
# @title External bwrap wrapper replaces broken built-in sandbox
# @status accepted
# @rationale Claude Code's built-in sandbox uses apply-seccomp which fails on Ubuntu
#   with kernel.apparmor_restrict_unprivileged_userns=1. The nested user namespace
#   created by apply-seccomp inside bwrap's namespace is blocked by AppArmor's
#   capability restrictions. This wrapper uses bwrap directly (no apply-seccomp),
#   combined with --dangerously-skip-permissions to eliminate shell-operator prompts.
#   Filesystem isolation is enforced by bwrap; hooks provide governance.

set -euo pipefail

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
claude-sandbox.sh — Launch Claude Code inside a bwrap OS-level sandbox

USAGE
    claude-sandbox.sh [PROJECT_DIR] [-- CLAUDE_ARGS...]
    claude-sandbox.sh --help

ARGUMENTS
    PROJECT_DIR     Directory to sandbox (default: $PWD). Must exist.
    CLAUDE_ARGS     Extra arguments forwarded to claude after --dangerously-skip-permissions.

DESCRIPTION
    Wraps Claude Code in a bubblewrap (bwrap) sandbox to provide filesystem
    isolation. The sandbox:

      - Mounts the project directory read-write (everything else read-only
        or absent)
      - Grants read-write access to ~/.claude and ~/.claude-traces
      - Includes full network access (no --unshare-net)
      - Uses --dangerously-skip-permissions to suppress shell-operator prompts
        (governance is enforced by hooks, not interactive prompts)
      - Skips any bind that does not exist on this system (safe on heterogeneous
        machines)

    This replaces Claude Code's built-in sandbox, which fails on Ubuntu
    systems where kernel.apparmor_restrict_unprivileged_userns=1 prevents
    nested user namespaces (apply-seccomp fails inside bwrap's namespace).

REQUIREMENTS
    bwrap (bubblewrap) must be installed:
        sudo apt install bubblewrap

EXAMPLES
    # Sandbox current directory
    claude-sandbox.sh

    # Sandbox a specific project
    claude-sandbox.sh ~/projects/myapp

    # Pass extra flags to claude
    claude-sandbox.sh ~/projects/myapp -- --model claude-opus-4-5

EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

# First positional arg (if not starting with -) is the project dir
if [[ -n "${1:-}" && "${1:-}" != "--" && "${1:-}" != -* ]]; then
    PROJECT_DIR="$1"
    shift
else
    PROJECT_DIR="${PWD}"
fi

# Remaining args (after optional --) are forwarded to claude
if [[ "${1:-}" == "--" ]]; then
    shift
fi
EXTRA_ARGS=("$@")

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

if ! command -v bwrap &>/dev/null; then
    echo "ERROR: bwrap not found. Install it with: sudo apt install bubblewrap" >&2
    exit 1
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: Project directory does not exist: $PROJECT_DIR" >&2
    exit 1
fi

# Resolve to absolute path
PROJECT_DIR="$(realpath "$PROJECT_DIR")"

# ---------------------------------------------------------------------------
# Ensure required host directories exist before binding
# ---------------------------------------------------------------------------

mkdir -p "$HOME/.claude"
mkdir -p "$HOME/.claude-traces"

# ---------------------------------------------------------------------------
# Startup announcement
# ---------------------------------------------------------------------------

echo "claude-sandbox: sandboxing project: $PROJECT_DIR"
echo "claude-sandbox: --dangerously-skip-permissions is active (governance via hooks)"

# ---------------------------------------------------------------------------
# Build bwrap argument array incrementally
# ---------------------------------------------------------------------------

args=()

# -- Namespace isolation (no --unshare-net: full network access required)
args+=(
    --unshare-user
    --unshare-pid
    --unshare-ipc
    --unshare-uts
    --unshare-cgroup
)

# -- System (read-only)
args+=(
    --ro-bind /usr /usr
    --symlink usr/lib /lib
    --symlink usr/lib64 /lib64
    --symlink usr/bin /bin
    --symlink usr/sbin /sbin
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --tmpfs /var/tmp
)

# -- /etc essentials (read-only, conditional)
# Each path is checked before binding so the script is portable across machines.
ro_bind_if_exists() {
    local src="$1"
    local dst="${2:-$1}"
    [[ -e "$src" ]] && args+=(--ro-bind "$src" "$dst")
}

ro_bind_if_exists /etc/resolv.conf
ro_bind_if_exists /etc/ssl
ro_bind_if_exists /etc/ca-certificates
ro_bind_if_exists /etc/passwd
ro_bind_if_exists /etc/group
ro_bind_if_exists /etc/hostname
ro_bind_if_exists /etc/npmrc
ro_bind_if_exists /etc/ld.so.conf
ro_bind_if_exists /etc/ld.so.conf.d
ro_bind_if_exists /etc/ld.so.cache

# -- Project directory (read-write)
args+=(--bind "$PROJECT_DIR" "$PROJECT_DIR")

# -- Claude config and traces (read-write)
args+=(
    --bind "$HOME/.claude" "$HOME/.claude"
    --bind "$HOME/.claude-traces" "$HOME/.claude-traces"
)

# -- User toolchain (read-only, conditional)
ro_bind_if_exists "$HOME/.cargo"
ro_bind_if_exists "$HOME/.local/bin"
ro_bind_if_exists "$HOME/.local/share/uv"
ro_bind_if_exists "$HOME/.local/share/claude"
ro_bind_if_exists "$HOME/go"
ro_bind_if_exists "$HOME/.npm"
ro_bind_if_exists "$HOME/.gitconfig"
ro_bind_if_exists "$HOME/.config/git"
ro_bind_if_exists "$HOME/.config/go"
ro_bind_if_exists "$HOME/.config/gh"

# -- SSH agent socket (only if set and the socket actually exists)
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
    args+=(--ro-bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK")
fi

# -- Node global modules (for claude CLI and other global npm packages)
ro_bind_if_exists /usr/local/lib/node_modules
ro_bind_if_exists /usr/local/bin

# -- Runtime flags
args+=(
    --die-with-parent
    --chdir "$PROJECT_DIR"
)

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

exec bwrap "${args[@]}" -- claude --dangerously-skip-permissions "${EXTRA_ARGS[@]}"
