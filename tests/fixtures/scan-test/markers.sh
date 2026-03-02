#!/usr/bin/env bash
# markers.sh — Test fixture with various debt markers for scan-backlog.sh tests.
# This file intentionally contains markers — do not refactor them away.

# TODO: implement proper retry logic here
echo "placeholder for retry"

# FIXME: this breaks on macOS due to BSD sed vs GNU sed
sed -i 's/foo/bar/' somefile.txt

# HACK: works around a gh API timeout — replace with proper polling
sleep 2

# Check something
if true; then
    echo "ok"
fi

# XXX: this is fragile — depends on undocumented API behavior
curl "https://api.example.com/v1/internal" 2>/dev/null

# OPTIMIZE: this loop runs O(n^2) — replace with hash lookup
for i in {1..100}; do
    for j in {1..100}; do
        echo "$i $j"
    done
done

# WORKAROUND: upstream bug in bash 5.0 — remove when 5.2 is baseline
export BASH_COMPAT=4.4

# TEMP: remove after migration is complete
LEGACY_MODE=true
