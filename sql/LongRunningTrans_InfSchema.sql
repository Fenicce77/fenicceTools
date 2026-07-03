 -- SELECT trx_mysql_thread_id AS process_id,trx_isolation_level,TIMEDIFF(NOW(),trx_started) AS trx_runtime,trx_state,trx_rows_locked,trx_rows_modified,trx_query AS query
 -- FROM information_schema.INNODB_TRX
 -- WHERE trx_started < CURRENT_TIME - INTERVAL 1 SECOND \G

--    trx_is_read_only
 SELECT 
    trx.trx_id,
    trx.trx_mysql_thread_id AS process_id,
    trx_isolation_level,
    TIMEDIFF(NOW(),trx.trx_started) AS trx_runtime,
    trx.trx_state,
    trx.trx_rows_locked,
    trx.trx_rows_modified,
    trx.trx_query AS query,
    concat(p.user,'@',p.host) AS fullusername,
    trx.trx_requested_lock_id,
    trx.trx_tables_in_use,
    trx.trx_tables_locked

FROM 
    information_schema.INNODB_TRX trx JOIN information_schema.processlist p on trx.trx_mysql_thread_id=p.id
WHERE trx.trx_mysql_thread_id not in (CONNECTION_ID()) and trx.trx_id not in (0) and trx_started < CURRENT_TIME - INTERVAL 1 SECOND \G
