#!/usr/bin/env bash
# clean.sh — Test fixture with NO debt markers for scan-backlog.sh tests.
# Used to verify exit code 1 when no markers exist.

# This is a well-maintained file with no outstanding debt.
set -euo pipefail

main() {
    echo "Clean implementation — no markers here."
    return 0
}

main "$@"
