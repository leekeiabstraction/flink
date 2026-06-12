-- Stateful GROUP BY job whose CAST in WHERE throws NumberFormatException on
-- every row of the random datagen stream. Each restart forces a fresh
-- RocksDB keyed state backend build → exercises the Statistics allocation
-- path repeatedly. Restart delay is 100ms (configured cluster-wide).

CREATE TEMPORARY TABLE datagen_source (
  id BIGINT,
  payload STRING,
  ts AS PROCTIME()
) WITH (
  'connector' = 'datagen',
  'rows-per-second' = '100',
  'fields.id.kind' = 'random',
  'fields.id.min' = '0',
  'fields.id.max' = '1000000',
  'fields.payload.length' = '256'
);

CREATE TEMPORARY TABLE blackhole_sink (
  id BIGINT,
  cnt BIGINT,
  max_payload STRING
) WITH (
  'connector' = 'blackhole'
);

-- CAST in WHERE so the optimizer can't prune it. Random payload is never
-- numeric, so every row triggers a NumberFormatException and fails the task.
INSERT INTO blackhole_sink
SELECT id, COUNT(*) AS cnt, MAX(payload) AS max_payload
FROM datagen_source
WHERE CAST(payload AS BIGINT) > -999999999
GROUP BY id;
