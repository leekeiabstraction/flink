# RocksDB Statistics native memory leak — local reproduction

Reproduces the native memory leak attributed to `Java_org_rocksdb_Statistics_newStatistics`
→ `CoreLocalArray::CoreLocalArray` → `rocksdb::port::cacheline_aligned_alloc`
seen in TaskManagers that enable native RocksDB ticker metrics and undergo
repeated keyed state backend rebuilds (job restarts, rescaling).

## What it does

- Brings up JobManager + TaskManager on `flink:2.2.1-java21` (configurable).
- Mounts `flink-statebackend-rocksdb` and `frocksdbjni` JARs into the cluster
  (the official OSS image doesn't ship RocksDB state backend).
- Enables all 11 RocksDB ticker metrics → makes every backend build call
  `new org.rocksdb.Statistics()`.
- Submits 4 copies of a stateful GROUP BY job whose CAST in WHERE throws
  `NumberFormatException` on every row → each task fails immediately.
- With `restart-strategy.fixed-delay.delay=100ms`, each slot rebuilds its
  keyed state backend ~10×/sec across 4 slots → ~40 backend builds/sec.

## Quick start

```bash
./run.sh                            # default: stats ON, 4 slots, 4 jobs
STATS_ENABLED=false ./run.sh        # control run with ticker metrics disabled
SLOTS=8 N=8 ./run.sh                # crank the churn rate up further
FLINK_IMAGE=my-flink:dev ./run.sh   # verify a local build
```

Tear down:

```bash
docker compose down
```

## Expected outcome

| Run | Outcome |
|---|---|
| **`STATS_ENABLED=true`** (default) | TaskManager OOMKilled within **~1–2 minutes** of cluster start. `docker inspect` reports `OOMKilled: true, ExitCode: 137`. |
| **`STATS_ENABLED=false`** | TaskManager stays alive indefinitely. cgroup `memory.current` plateaus around ~2.3 GB (no monotonic climb). |

Quick check on the container after a run:

```bash
docker inspect stats-leak-tm --format 'Status:{{.State.Status}}  OOMKilled:{{.State.OOMKilled}}  ExitCode:{{.State.ExitCode}}'
```

## Container sizing rationale

The TM container limit is **4 GB**, while Flink's process budget is also
**4096 MB**. With essentially zero headroom past budget:

- A well-behaved Flink fills to ~3.9 GB and stays there.
- A leaking Flink pushes past 4 GB and gets OOM-killed by the kernel.

This is why stats-ON OOMs fast (we're leaking past budget) while stats-OFF
sits stable.

## File layout

| File | Purpose |
|---|---|
| `docker-compose.yml` | JM + TM definition, all knobs via env vars |
| `entrypoint-with-lib.sh` | Copies the mounted extra JARs into `/opt/flink/lib` at container start |
| `setup.sh` | Downloads required JARs into `lib/` (idempotent) |
| `job.sql` | The continuously-failing stateful job |
| `submit-jobs.sh` | Submits N copies of `job.sql` via `sql-client.sh` in the JM container |
| `run.sh` | End-to-end orchestrator |
| `lib/` | Downloaded JARs (populated by `setup.sh`) |
