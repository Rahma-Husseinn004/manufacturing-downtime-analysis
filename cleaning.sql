-- =====================================================
-- Manufacturing Line Productivity - Data Cleaning (SQL)
-- Raw tables expected: raw_productivity, raw_products,
-- raw_factors, raw_downtime  (loaded as-is from Excel)
-- =====================================================

-- 1) Production: fix dates + midnight crossing, add duration
DROP TABLE IF EXISTS fact_production;
CREATE TABLE fact_production AS
WITH base AS (
  SELECT batch, product, operator, date AS raw_date, start_time, end_time,
         LAG(end_time)  OVER (ORDER BY batch) AS prev_end,
         LAG(date)      OVER (ORDER BY batch) AS prev_date
  FROM raw_productivity
),
fixed AS (
  SELECT batch, product, operator, start_time, end_time,
         -- if batch starts exactly when the previous one ended, it is the same run -> same date
         CASE WHEN start_time = prev_end THEN prev_date ELSE raw_date END AS batch_date
  FROM base
),
dur AS (
  SELECT *,
    ( (CAST(substr(end_time,1,2) AS INT)*60 + CAST(substr(end_time,4,2) AS INT))
    - (CAST(substr(start_time,1,2) AS INT)*60 + CAST(substr(start_time,4,2) AS INT)) + 1440 ) % 1440
    AS duration_min
  FROM fixed
)
SELECT batch, TRIM(product) AS product, TRIM(operator) AS operator, batch_date,
       batch_date || ' ' || start_time AS start_dt,
       datetime(batch_date || ' ' || start_time, '+' || duration_min || ' minutes') AS end_dt,
       duration_min
FROM dur;

-- 2) Products: clean types
DROP TABLE IF EXISTS dim_product;
CREATE TABLE dim_product AS
SELECT TRIM(product) AS product, TRIM(flavor) AS flavor, TRIM(size) AS size,
       CAST(min_batch_time AS INT) AS min_batch_min
FROM raw_products;

-- 3) Downtime factors: Yes/No -> 1/0
DROP TABLE IF EXISTS dim_downtime_factor;
CREATE TABLE dim_downtime_factor AS
SELECT CAST(factor AS INT) AS factor_id, TRIM(description) AS factor_name,
       CASE WHEN operator_error = 'Yes' THEN 1 ELSE 0 END AS is_operator_error
FROM raw_factors;

-- 4) Downtime: wide -> long (drop NULLs), with factor names
DROP TABLE IF EXISTS fact_downtime;
CREATE TABLE fact_downtime AS
WITH u AS (
  SELECT batch, 1 AS factor_id, f1 AS minutes FROM raw_downtime UNION ALL
  SELECT batch, 2,  f2  FROM raw_downtime UNION ALL
  SELECT batch, 3,  f3  FROM raw_downtime UNION ALL
  SELECT batch, 4,  f4  FROM raw_downtime UNION ALL
  SELECT batch, 5,  f5  FROM raw_downtime UNION ALL
  SELECT batch, 6,  f6  FROM raw_downtime UNION ALL
  SELECT batch, 7,  f7  FROM raw_downtime UNION ALL
  SELECT batch, 8,  f8  FROM raw_downtime UNION ALL
  SELECT batch, 9,  f9  FROM raw_downtime UNION ALL
  SELECT batch, 10, f10 FROM raw_downtime UNION ALL
  SELECT batch, 11, f11 FROM raw_downtime UNION ALL
  SELECT batch, 12, f12 FROM raw_downtime
)
SELECT u.batch, u.factor_id, d.factor_name, d.is_operator_error, u.minutes
FROM u JOIN dim_downtime_factor d USING (factor_id)
WHERE u.minutes IS NOT NULL;

-- 5) Final analysis view: one row per batch
DROP VIEW IF EXISTS v_batch_summary;
CREATE VIEW v_batch_summary AS
SELECT p.*, pr.min_batch_min,
       p.duration_min - pr.min_batch_min AS excess_min,
       COALESCE(SUM(d.minutes),0) AS total_downtime_min,
       COALESCE(SUM(CASE WHEN d.is_operator_error=1 THEN d.minutes END),0) AS operator_error_min
FROM fact_production p
JOIN dim_product pr USING (product)
LEFT JOIN fact_downtime d USING (batch)
GROUP BY p.batch;

-- 6) Validation: excess time must equal logged downtime (expect 0 rows)
SELECT * FROM v_batch_summary WHERE excess_min <> total_downtime_min;
