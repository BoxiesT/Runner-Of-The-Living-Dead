#!/bin/bash
# Runs one scenario with TWO headless editors (host + client, separate project copies).
#   usage: run_pair.sh <projA> <projB> <scenario> [port]     env: GODOT, OUT, TMO, T0_DELAY, EXTRA_ARGS
HERE="$(cd "$(dirname "$0")" && pwd)"
GODOT="${GODOT:-godot}"
A="$1"; B="$2"; SC="$3"; PORT="${4:-$((25000 + RANDOM % 5000))}"
OUT="${OUT:-${TMPDIR:-/tmp}/glc_out}"; mkdir -p "$OUT"; rm -f "$OUT"/*.json "$OUT"/*.log
for P in "$A" "$B"; do
  "$HERE/reset_proj.sh" "$P"
  mkdir -p "$P/addons/glc_driver"; cp "$HERE"/driver/addons/glc_driver/* "$P/addons/glc_driver/"
done
T0=$(python3 -c "import time; print(time.time()+${T0_DELAY:-14})")
( cd "$A" && timeout "${TMO:-150}" "$GODOT" --headless --editor --path . --quit-after 100000 -- --glc-role=host   --glc-scenario="$SC" --glc-port="$PORT" --glc-t0="$T0" --glc-out="$OUT/host.json"   $EXTRA_ARGS > "$OUT/host.log"   2>&1 ) &
PA=$!
sleep 0.5
( cd "$B" && timeout "${TMO:-150}" "$GODOT" --headless --editor --path . --quit-after 100000 -- --glc-role=client --glc-scenario="$SC" --glc-port="$PORT" --glc-t0="$T0" --glc-out="$OUT/client.json" $EXTRA_ARGS > "$OUT/client.log" 2>&1 ) &
PB=$!
wait $PA $PB
for r in host client; do
  sed 's/\x1b\[[0-9;]*m//g' "$OUT/$r.log" | grep -E "SCRIPT ERROR|^ERROR|Invalid|Nonexistent" | grep -v "Couldn't open directory\|Parameter \"t\" is null\|!_is_active\|Parse Error: Unexpected identifier\|still in use at exit" | sort | uniq -c | head -8 | sed "s/^/[$r] /"
done
