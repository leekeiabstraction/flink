SET 'table.dml-sync' = 'false';

CREATE TEMPORARY TABLE src (
  k  BIGINT,
  s1 STRING,
  s2 STRING,
  s3 STRING,
  s4 STRING,
  n1 BIGINT,
  n2 INT,
  n3 DOUBLE
) WITH (
  'connector'        = 'datagen',
  'rows-per-second'  = '100000',
  'fields.k.kind'    = 'random',
  'fields.k.min'     = '0',
  'fields.k.max'     = '5000000',
  'fields.s1.length' = '128',
  'fields.s2.length' = '128',
  'fields.s3.length' = '128',
  'fields.s4.length' = '128'
);

CREATE TEMPORARY TABLE sink (
  k      BIGINT,
  cnt    BIGINT,
  m_s1   STRING,
  m_s2   STRING,
  m_s3   STRING,
  m_s4   STRING,
  sum_n1 BIGINT,
  max_n2 INT,
  min_n3 DOUBLE
) WITH (
  'connector' = 'blackhole'
);

INSERT INTO sink
SELECT
  k,
  COUNT(*),
  MAX(s1), MAX(s2), MAX(s3), MAX(s4),
  SUM(n1), MAX(n2), MIN(n3)
FROM src
GROUP BY k;
