-- 1. Input your daily expectations
-- SET @daily_new_rows = 11300;      -- How many rows you expect per day
-- SET @retention_days = 30;        -- How many days you plan to keep data


SELECT 
    TABLE_SCHEMA, TABLE_NAME,  @daily_new_rows AS daily_rows,
    -- Data + Index Total per day in MB
    ROUND((SUM(est_bytes_per_col) * (1 + (0.3 * num_indexes)) * @daily_new_rows * 1.2) / 1024 / 1024, 2) AS daily_total_mb,
    ROUND((SUM(est_bytes_per_col) * (1 + (0.3 * num_indexes)) * @daily_new_rows * 1.2) / 1024 / 1024/ 1024, 2) AS daily_total_gb,
    ROUND((SUM(est_bytes_per_col) * (30 + (0.3 * num_indexes)) * @daily_new_rows * 1.2) / 1024 / 1024, 2) AS daily_total_mb,
    ROUND((SUM(est_bytes_per_col) * (30 + (0.3 * num_indexes)) * @daily_new_rows * 1.2) / 1024 / 1024/ 1024, 2) AS monthly_total_gb,
    (30 * @daily_new_rows) as monthly_estimated_rows,
    ROUND((SUM(est_bytes_per_col) * (1 + (0.3 * num_indexes)) * @daily_new_rows * @retention_days * 1.2) / 1024 / 1024 / 1024, 2) AS total_retention_gb
FROM (
    SELECT 
        c.TABLE_SCHEMA, 
        c.TABLE_NAME,
        (SELECT COUNT(DISTINCT INDEX_NAME) - 1 FROM information_schema.STATISTICS 
         WHERE TABLE_SCHEMA = c.TABLE_SCHEMA AND TABLE_NAME = c.TABLE_NAME) as num_indexes,
        CASE 
            -- Fixed & Numeric Types
            WHEN DATA_TYPE IN ('tinyint', 'bool') THEN 1
            WHEN DATA_TYPE = 'smallint' THEN 2
            WHEN DATA_TYPE = 'int' THEN 4
            WHEN DATA_TYPE = 'bigint' THEN 8
            WHEN DATA_TYPE IN ('datetime', 'timestamp') THEN 8            
            -- String Types (VARCHAR/CHAR)
            WHEN CHARACTER_OCTET_LENGTH IS NOT NULL AND DATA_TYPE NOT LIKE '%text%' THEN CHARACTER_OCTET_LENGTH            
            -- BLOB / TEXT Types (Handling the "Missing" lengths)
            -- We use the typical 'pointer' size + an estimated average content size
            WHEN DATA_TYPE = 'tinytext' THEN 255
            WHEN DATA_TYPE = 'text' THEN 1000      -- Adjust based on your average expected string
            WHEN DATA_TYPE = 'mediumtext' THEN 5000 -- Adjust based on your average expected string
            WHEN DATA_TYPE = 'longtext' THEN 10000  -- Adjust based on your average expected string
            
            ELSE 8 
        END AS est_bytes_per_col
    FROM information_schema.COLUMNS c
    WHERE c.TABLE_SCHEMA = 'dev_kyc_engine' 
      AND c.TABLE_NAME like 'kyc_account_status%'
) AS col_stats
GROUP BY TABLE_SCHEMA, TABLE_NAME, num_indexes;


-- SELECT 
--     TABLE_SCHEMA, TABLE_NAME, @daily_new_rows AS rows_per_day,
    
--     -- Daily Growth in MB
--     ROUND((SUM(max_bytes_per_column) * @daily_new_rows * 1.2) / 1024 / 1024, 2) AS init_from_profile_population_mb,
    
--     -- Daily Growth in MB
--     ROUND((SUM(max_bytes_per_column) * @daily_new_rows * 1.2) / 1024 / 1024 / 1024, 2) AS init_from_profile_population_gb,

--     -- Daily Growth in TB
--     ROUND((SUM(max_bytes_per_column) * @daily_new_rows * 1.2) / 1024 / 1024 / 1024 / 1024, 2) AS init_from_profile_population_tb
-- FROM (
--     SELECT 
--         TABLE_SCHEMA, 
--         TABLE_NAME,
--         COLUMN_NAME,
--         CASE 
--             WHEN DATA_TYPE IN ('tinyint', 'bool') THEN 1
--             WHEN DATA_TYPE = 'smallint' THEN 2
--             WHEN DATA_TYPE = 'mediumint' THEN 3
--             WHEN DATA_TYPE = 'int' THEN 4
--             WHEN DATA_TYPE = 'bigint' THEN 8
--             WHEN DATA_TYPE = 'float' THEN 4
--             WHEN DATA_TYPE = 'double' THEN 8
--             WHEN DATA_TYPE = 'date' THEN 3
--             WHEN DATA_TYPE IN ('datetime', 'timestamp') THEN 8
--             WHEN DATA_TYPE = 'time' THEN 3
--             WHEN CHARACTER_OCTET_LENGTH IS NOT NULL THEN CHARACTER_OCTET_LENGTH
--             ELSE 8 
--         END AS max_bytes_per_column
--     FROM information_schema.COLUMNS
--     WHERE TABLE_SCHEMA = 'dev_kyc_engine' AND TABLE_NAME in ('kyc_account_status','kyc_account_status_new')
-- ) AS col_stats
-- GROUP BY TABLE_SCHEMA, TABLE_NAME;



-- SELECT 
--     TABLE_SCHEMA,
--     TABLE_NAME,
--     @daily_new_rows AS daily_rows,
    
--     -- Calculated Data Size (MB)
--     ROUND((SUM(max_bytes_per_column) * @daily_new_rows * 1.2) / 1024 / 1024, 2) AS daily_data_mb,
    
--     -- Estimated Index Size (MB) 
--     -- Logic: We assume each secondary index is roughly 25-30% of the data size
--     ROUND(((SUM(max_bytes_per_column) * 0.3 * num_indexes) * @daily_new_rows * 1.2) / 1024 / 1024, 2) AS daily_index_mb,
    
--     -- Total Daily Growth (Data + Indexes)
--     ROUND(((SUM(max_bytes_per_column) * (1 + (0.3 * num_indexes))) * @daily_new_rows * 1.2) / 1024 / 1024, 2) AS total_daily_mb,
    
--     -- Total Storage needed for the full Retention Period (GB)
--     ROUND((((SUM(max_bytes_per_column) * (1 + (0.3 * num_indexes))) * @daily_new_rows * @retention_days * 1.2)) / 1024 / 1024 / 1024, 2) AS total_retention_gb
-- FROM (
--     SELECT 
--         c.TABLE_SCHEMA, 
--         c.TABLE_NAME,
--         c.COLUMN_NAME,
--         -- Get count of secondary indexes for this table
--         (SELECT COUNT(DISTINCT INDEX_NAME) - 1 
--          FROM information_schema.STATISTICS 
--          WHERE TABLE_SCHEMA = c.TABLE_SCHEMA AND TABLE_NAME = c.TABLE_NAME) as num_indexes,
--         CASE 
--             WHEN DATA_TYPE IN ('tinyint', 'bool') THEN 1
--             WHEN DATA_TYPE = 'smallint' THEN 2
--             WHEN DATA_TYPE = 'mediumint' THEN 3
--             WHEN DATA_TYPE = 'int' THEN 4
--             WHEN DATA_TYPE = 'bigint' THEN 8
--             WHEN DATA_TYPE = 'float' THEN 4
--             WHEN DATA_TYPE = 'double' THEN 8
--             WHEN DATA_TYPE = 'date' THEN 3
--             WHEN DATA_TYPE IN ('datetime', 'timestamp') THEN 8
--             WHEN DATA_TYPE = 'time' THEN 3
--             WHEN CHARACTER_OCTET_LENGTH IS NOT NULL THEN CHARACTER_OCTET_LENGTH
--             ELSE 8 
--         END AS max_bytes_per_column
--     FROM information_schema.COLUMNS c
--     WHERE c.TABLE_SCHEMA = 'dev_kyc_engine' AND TABLE_NAME in ('kyc_account_status','kyc_account_status_new')
-- ) AS col_stats
-- GROUP BY TABLE_SCHEMA, TABLE_NAME, num_indexes;