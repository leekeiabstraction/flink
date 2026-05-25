# Repro: RocksDB `getDescriptor()` native leak via manual compaction

Reproduces the leak in `Compactor.compact()` (`cfName.getDescriptor().getOptions()` allocates
a native `ColumnFamilyOptions` that is never closed, pinning the shared block cache's
`shared_ptr`). The production symptom is RSS growing past the configured block-cache capacity
across operator rescales/restarts.

We compress prod's ~6h into minutes with three levers:
1. **Gate 1** — tiny RocksDB write buffers / file sizes so small SSTs reach L1+ in seconds.
2. **Gate 2** — aggressive manual-compaction settings so `Compactor.compact()` fires constantly.
3. **Cycle** — a session cluster + submit/cancel loop = many "generations" in one TM process.

## Why a session cluster
This is a *native* (off-heap) leak. It only accumulates if the leaked objects stay in the
**same address space**. A session cluster keeps the TaskManager alive across job
submit/cancel cycles, so old block caches (pinned by leaked descriptors) pile up and RSS
climbs. A per-job / application cluster tears the TM down each cycle and frees everything —
it would **never** reproduce this, no matter how long you run it.

## Prerequisites
- Docker + Docker Compose.
- The stock `flink:1.20` (or `flink:2.0`) image already contains the bug.

## Run
```bash
cd sst-leak-repro
docker compose up -d                 # start session cluster; UI at http://localhost:8081
chmod +x run-cycles.sh
./run-cycles.sh 30 90                 # 30 generations, 90s each; prints TM mem each cycle
```
Watch live in another terminal:
```bash
watch -n2 'docker stats --no-stream --format "{{.Name}} {{.MemUsage}}"'
```

## What you should see
- **Buggy image (stock):** TaskManager `MEM USAGE` ratchets up every cycle and does not return
  to baseline after cancel — it keeps climbing past the 512m managed-memory budget.
- **Confirming signal:** in the Flink UI (TaskManager → Metrics) or via REST, the live
  `...block-cache-usage` stays bounded near capacity while container RSS keeps growing. That gap
  = memory held by caches that are no longer live but can't be freed = the leak.

## Verifying the fix
The fix isn't in any public image, so build one from a branch that closes the descriptor and
point `image:` in `docker-compose.yml` at it, then rerun. Expected: RSS plateaus across cycles
and the block-cache-usage/RSS gap stays flat.

## Optional: jemalloc heap profile (matches the prod jeprof output)
The official images use jemalloc by default. To capture `ReadBlockContents`-style profiles, add
to the `taskmanager` service environment:
```yaml
      - MALLOC_CONF=prof:true,prof_active:true,lg_prof_sample:19,lg_prof_interval:30,prof_prefix:/tmp/jeprof/jeprof
```
then `mkdir -p /tmp/jeprof` inside the container and analyze the dumped `*.heap` files with
`jeprof` against the libjemalloc in the image.

## Tuning (if it's not climbing fast enough)
- Raise `rows-per-second` in `job.sql` and/or `fields.k.max` (more keys = more state = more SSTs).
- Increase `RUN_SECONDS` so each generation accumulates more compactions before cancel.
- Lower `manual-compaction.max-output-file-size` / `max-files-to-compact` => more, smaller tasks
  => more `compact()` calls per scan => faster leak.
- If files aren't reaching L1+, lower `writebuffer.size` further or check the UI for SST counts.

## Gotchas that silently produce "no leak"
- `manual-compaction.min-interval: 0` (the default) disables the feature entirely.
- `max-file-size-to-compact` (default 50k) **smaller than your SST files** => nothing qualifies.
- Using ForSt/HashMap backend instead of `state.backend.type: rocksdb`.
- A non-session cluster (TM dies per job).
