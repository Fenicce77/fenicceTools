 -- SELECT trx_mysql_thread_id AS process_id,trx_isolation_level,TIMEDIFF(NOW(),trx_started) AS trx_runtime,trx_state,trx_rows_locked,trx_rows_modified,trx_query AS query
 -- FROM information_schema.INNODB_TRX
 -- WHERE trx_started < CURRENT_TIME - INTERVAL 1 SECOND \G

 SELECT 
    trx_id, trx_started,
    CONVERT_TZ(trx_started,'+0:00','+3:00') AS trx_started_tz,
    trx_mysql_thread_id AS process_id,
    trx_isolation_level,
    TIMEDIFF(NOW(),CONVERT_TZ(trx_started,'+0:00','+3:00')) AS trx_runtime,
    trx_state,
    trx_rows_locked,
    trx_rows_modified,
    trx_query AS query,
    concat(p.user,'@',p.host) AS fullusername,
    trx_requested_lock_id,
    trx_tables_in_use,
    trx_tables_locked
--    ,trx_is_read_only
FROM 
    information_schema.INNODB_TRX trx JOIN information_schema.processlist p on trx.trx_mysql_thread_id=p.id
WHERE trx_started < CURRENT_TIME - INTERVAL 1 SECOND \G

-- SELECT 
--     trx_id,
--     trx_started,now() as curdatetime,
--     trx_mysql_thread_id AS process_id,
--     trx_isolation_level,
--     TIMEDIFF(NOW(),trx_started) AS trx_runtime,
--     trx_state,
--     trx_rows_locked,
--     trx_rows_modified,
--     trx_query AS query,
--     concat(p.user,'@',p.host) AS fullusername,
--     trx_requested_lock_id,
--     trx_tables_in_use,
--     trx_tables_locked
-- --    ,trx_is_read_only
-- FROM 
--     information_schema.INNODB_TRX trx JOIN information_schema.processlist p on trx.trx_mysql_thread_id=p.id
-- WHERE trx_started < CURRENT_TIME - INTERVAL 1 SECOND \G


-- SELECT 
--     trx_id, trx_started,
--     CONVERT_TZ(trx_started,'+0:00','-3:00') AS trx_started_tz,
--     trx_mysql_thread_id AS process_id,
--     trx_isolation_level,
--     TIMEDIFF(NOW(),CONVERT_TZ(trx_started,'+0:00','-3:00')) AS trx_runtime,
--     trx_state,
--     trx_rows_locked,
--     trx_rows_modified,
--     trx_query AS query,
--     concat(p.user,'@',p.host) AS fullusername,
--     trx_requested_lock_id,
--     trx_tables_in_use,
--     trx_tables_locked
-- --    ,trx_is_read_only
-- FROM 
--     information_schema.INNODB_TRX trx JOIN information_schema.processlist p on trx.trx_mysql_thread_id=p.id
-- WHERE trx_started < CURRENT_TIME - INTERVAL 1 SECOND \G