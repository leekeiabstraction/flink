#!/usr/bin/env bash
# End-to-end repro:
#   1. download required JARs (idempotent)
#   2. bring cluster up
#   3. submit N jobs
#
# Knobs (env vars):
#   STATS_ENABLED   true | false   (default true — the leak repro)
#   SLOTS           4              (default 4)
#   N               4              (jobs to submit; default 4)
#   FLINK_IMAGE     flink:2.2.1-java21
#   WEB_UI_PORT     8086
set -euo pipefail
cd "$(dirname "$0")"

STATS_ENABLED="${STATS_ENABLED:-true}"
SLOTS="${SLOTS:-4}"
N="${N:-4}"

export STATS_ENABLED SLOTS

echo "==[1] setup: download JARs if missing]=="
./setup.sh

echo
echo "==[2] docker compose up -d]=="
docker compose down --remove-orphans 2>&1 | tail -3 || true
docker compose up -d 2>&1 | tail -5

echo
echo "==[3] wait for JM + TM to be ready]=="
until curl -sf http://localhost:${WEB_UI_PORT:-8086}/overview >/dev/null 2>&1; do sleep 1; done && echo "  JM ready"
until [ "$(curl -sf http://localhost:${WEB_UI_PORT:-8086}/overview | grep -oE '"slots-total":[0-9]+' | grep -oE '[0-9]+')" -ge "$SLOTS" ]; do sleep 1; done && echo "  TM ready ($SLOTS slots)"

echo
echo "==[4] submit $N jobs]=="
N="$N" ./submit-jobs.sh

echo
echo "Cluster is running. Web UI: http://localhost:${WEB_UI_PORT:-8086}"
echo "Tear down with:  docker compose down"
