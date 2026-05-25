# Steps to trigger the OOMKill (RocksDB `getDescriptor()` native leak)

End-to-end procedure to drive a TaskManager to a Docker **OOMKill (exit 137)** caused by the
leak in `Compactor.compact()` — `cfName.getDescriptor()` allocates a native
`ColumnFamilyOptions` that is never closed, pinning each generation's RocksDB block cache so
it is never freed across job submit/cancel cycles.

Observed in this run: idle baseline **1.08 GiB** → idle after gen 1 **3.85 GiB** (never released)
→ gen 2 pushes RSS to the **4 GiB** cap → **OOMKilled, exit 137** within ~20s.

---

## Why these conditions are required (all already baked into `docker-compose.yml`)

| Condition | Setting | Why it matters |
|---|---|---|
| Session cluster (TM survives cycles) | JM + long-lived TM | Native leak only accumulates in the *same* process. Per-job clusters free it each cycle → never reproduces. |
| Manual compaction ON | `manual-compaction.min-interval: 5s` | `0` disables the feature → zero leak. This is the only thing that calls the leaking `Compactor.compact()`. |
| Manual compactions actually *succeed* | `compaction.level.max-size-level-base: 1mb` | Lets small files settle at L1 where auto-compaction ignores them, so the manual pass wins instead of failing "currently being compacted". |
| Small SSTs reach L1+ fast | `writebuffer.size: 64kb`, `target-file-size-base: 64kb` | Compresses prod's ~6h into seconds. |
| Files qualify for manual compaction | `manual-compaction.max-file-size-to-compact: 1mb` | Default 50k would exclude the 64kb files. |
| Fat per-key state (amplifier) | `job.sql`: 5M keys × ~550-byte accumulator | More state → more SST files → more pinned cache per generation → fewer cycles to OOM. |
| Hard kill on overrun | `mem_limit == process.size`, `memswap_limit == mem_limit` | Container limit == Flink budget, swap disabled → RSS overrun = real OOMKill (137), not slow swap. |
| Cache scales with TM | managed memory unset → `managed.fraction: 0.4` | ~1.34 GiB cache pool on the 4g TM. |

---

## Prerequisites
- Docker Desktop with **>6 GB** allocated to the VM (4g TM + 2g JM + overhead).
  Check: `docker info --format '{{.MemTotal}}'`.
- Run all commands from the `sst-leak-repro/` directory.

## Steps

### 1. Start a fresh session cluster
```bash
docker compose up -d --force-recreate
# wait for the TaskManager to register
until [ "$(curl -s localhost:8081/overview | python3 -c 'import sys,json;print(json.load(sys.stdin).get("taskmanagers",0))' 2>/dev/null)" = "1" ]; do sleep 2; done
```

### 2. Record the clean idle baseline (expect ~1.08 GiB)
```bash
TM=$(docker compose ps -q taskmanager)
docker stats --no-stream --format '{{.MemUsage}}' "$TM"
```

### 3. Run one generation: submit → churn 60s → cancel
```bash
docker compose exec -T jobmanager /opt/flink/bin/sql-client.sh -f /opt/sql/job.sql
sleep 6
JID=$(docker compose exec -T jobmanager /opt/flink/bin/flink list -r | grep -Eo '[0-9a-f]{32}' | head -1)
sleep 60
docker compose exec -T jobmanager /opt/flink/bin/flink cancel "$JID"
sleep 6
```

### 4. Measure idle RSS again — the leak signal
```bash
echo "running jobs: $(curl -s localhost:8081/overview | python3 -c 'import sys,json;print(json.load(sys.stdin)["jobs-running"])')"
docker stats --no-stream --format '{{.MemUsage}}' "$TM"
```
**Expected:** 0 jobs running, but RSS stays high (~3.85 GiB) and does **not** return to the
~1.08 GiB baseline. That retained memory is the leaked, still-pinned block cache.

### 5. Repeat step 3 until idle RSS nears the 4 GiB cap
After ~1–2 generations of the fat-state `job.sql`, idle RSS sits at ~3.85 GiB (96% of cap).

### 6. Start one more generation to tip it over
```bash
docker compose exec -T jobmanager /opt/flink/bin/sql-client.sh -f /opt/sql/job.sql
# watch it die
for i in $(seq 1 12); do
  printf '[%s] status=%s OOMKilled=%s exit=%s mem=%s\n' "$i" \
    "$(docker inspect "$TM" --format '{{.State.Status}}')" \
    "$(docker inspect "$TM" --format '{{.State.OOMKilled}}')" \
    "$(docker inspect "$TM" --format '{{.State.ExitCode}}')" \
    "$(docker stats --no-stream --format '{{.MemUsage}}' "$TM" 2>/dev/null)"
  [ "$(docker inspect "$TM" --format '{{.State.OOMKilled}}')" = "true" ] && { echo ">>> OOMKILLED"; break; }
  sleep 5
done
```

### 7. Confirm the kill
```bash
docker inspect "$TM" --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} Status={{.State.Status}}'
```
**Success = `OOMKilled=true ExitCode=137 Status=exited`.** (In Kubernetes this is a pod OOMKill → CrashLoopBackOff.)

---

## Faster / slower knobs
- **Faster OOM:** raise `rows-per-second` in `job.sql`; lower `taskmanager.memory.process.size`
  and the matching `mem_limit` (less headroom = fewer cycles).
- **Clearer staircase (more, smaller steps):** use the automated loop `./run-cycles.sh 30 90`,
  which submits/cancels and logs RSS each cycle.

## Verifying the fix (negative control)
Point `image:` in `docker-compose.yml` at a Flink build where `Compactor.compact()` closes the
descriptor, then repeat steps 1–6. **Expected:** after each cancel RSS falls back near the
~1.08 GiB baseline, idle floor stays flat, and the TM **never** OOMKills.

## Reset after a kill
```bash
docker compose up -d                 # restart the dead TM (comes back at ~1 GiB baseline)
# or
docker compose down                  # tear everything down
```
