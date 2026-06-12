#!/usr/bin/env bash
# Submit N copies of job.sql through the SQL client running inside the JM
# container. Each submission lands on its own slot.
set -euo pipefail
cd "$(dirname "$0")"

N="${N:-4}"
JM="${JM:-stats-leak-jm}"

docker cp job.sql "$JM":/tmp/job.sql >/dev/null

for i in $(seq 1 "$N"); do
    echo "=== job $i ==="
    docker exec "$JM" /opt/flink/bin/sql-client.sh -f /tmp/job.sql 2>&1 | grep -E 'Job ID|ERROR' | head -3
done

slots=$(curl -s http://localhost:${WEB_UI_PORT:-8086}/overview)
echo
echo "slots-total / running / available:"
echo "$slots" | grep -oE '"slots-(total|available)":[0-9]+|"jobs-running":[0-9]+'
