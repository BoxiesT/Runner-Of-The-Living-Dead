#!/bin/bash
# Runs every integration scenario and prints a PASS/FAIL table.   env: GODOT=/path/to/godot
HERE="$(cd "$(dirname "$0")" && pwd)"
export GODOT="${GODOT:-godot}"
W="${WORKDIR:-${TMPDIR:-/tmp}/glc_kit}"; mkdir -p "$W"
"$HERE/make_proj.sh" "$W/A" && cp -r "$W/A" "$W/B.tmp" && rm -rf "$W/B" && mv "$W/B.tmp" "$W/B"
SCENARIOS="${SCENARIOS:-tree_basic props_concurrent names_concurrent client_edits late_join big_subtree script_concurrent files_sync empty_join files_live tree_live tree_edge instance_reload discovery}"
fail=0
for sc in $SCENARIOS; do
  echo "=== $sc"
  "$HERE/run_pair.sh" "$W/A" "$W/B" "$sc" | head -12
  if python3 "$HERE/compare.py" | tee /tmp/glc_last.txt | grep -qE "DIVERGE|DIFFER|FAIL|ok: False"; then echo "--> FAIL"; cat /tmp/glc_last.txt | head -20; fail=1; else tail -n +1 /tmp/glc_last.txt | head -3; echo "--> PASS"; fi
done
exit $fail
