#!/usr/bin/env bash
#
# Submit the SQL job, let it churn state + run manual compactions, cancel it, repeat.
# Each cycle is one "generation" (like a rescale/restart in prod). With the bug, the
# TaskManager's RSS climbs every cycle because leaked descriptors pin each generation's
# block cache. With the fix, RSS plateaus.
#
# Usage: ./run-cycles.sh [CYCLES] [RUN_SECONDS]
#        ./run-cycles.sh 30 90
#
set -uo pipefail

CYCLES="${1:-30}"
RUN_SECONDS="${2:-90}"
COMPOSE="docker compose"

# Portable timeout: GNU `timeout` (Linux), `gtimeout` (macOS+coreutils), else no-op.
# sql-client -f detaches on its own after an async INSERT, so this is just a guard.
if command -v timeout >/dev/null 2>&1;  then TIMEOUT="timeout 120"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout 120"
else TIMEOUT=""; fi

tm_mem() {
  local id
  id="$($COMPOSE ps -q taskmanager)"
  [ -n "$id" ] && docker stats --no-stream --format '{{.MemUsage}}' "$id"
}

printf 'cycle,tm_mem_usage\n'
for i in $(seq 1 "$CYCLES"); do
  # Submit (async DML => sql-client returns after submitting). timeout guards against
  # any version where the client stays attached.
  $TIMEOUT $COMPOSE exec -T jobmanager \
      /opt/flink/bin/sql-client.sh -f /opt/sql/job.sql >/tmp/sql-submit.log 2>&1 || true

  sleep 5
  JOBID="$($COMPOSE exec -T jobmanager /opt/flink/bin/flink list -r 2>/dev/null \
            | grep -Eo '[0-9a-f]{32}' | head -n1 || true)"

  # Let the generation build state and run many manual compactions.
  sleep "$RUN_SECONDS"
  printf '%s,%s\n' "$i" "$(tm_mem)"

  # End this generation. The backend closes; leaked descriptors keep its cache alive.
  if [ -n "${JOBID:-}" ]; then
    $COMPOSE exec -T jobmanager /opt/flink/bin/flink cancel "$JOBID" >/dev/null 2>&1 || true
  fi
  sleep 8
done
