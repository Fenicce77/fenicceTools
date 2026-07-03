SELECT
	th.PROCESSLIST_ID as process_id,
	th.PROCESSLIST_USER as username,
	th.PROCESSLIST_HOST as user_host,
	trx.thread_id AS thread_id,
	trx.event_id AS trx_event_id,
	ROUND(trx.timer_wait/1000000000000,3) as trx_runtime,
	trx.isolation_level,
	trx.autocommit,
	stm.current_schema AS db,
	stm.sql_text AS query,
	stm.rows_affected AS rows_examined,
	stm.rows_affected AS rows_affected,
	stm.rows_sent AS rows_sent,
	IF(stm.end_event_id IS NULL, 'running', 'done') AS exec_state,
	ROUND(stm.timer_wait/1000000000000,3) as exec_time
FROM 
	performance_schema.events_transactions_current trx JOIN performance_schema.events_statements_current stm USING (thread_id) 
	JOIN performance_schema.threads th USING (thread_id)
WHERE trx.state = 'ACTIVE' AND trx.timer_wait > 1000000000000 * 1 \G

-- SELECT
-- 	ROUND(trx.timer_wait/1000000000000,3) as trx_runtime,
--	trx.thread_id AS thread_id,
--	trx.event_id AS trx_event_id,
--	trx.isolation_level,
--	trx.autocommit,
--	stm.current_schema AS db,
--	stm.sql_text AS query,
--	stm.rows_affected AS rows_examined,
--	stm.rows_affected AS rows_affected,
--	stm.rows_sent AS rows_sent,
--	IF(stm.end_event_id IS NULL, 'running', 'done') AS exec_state,
--	ROUND(stm.timer_wait/1000000000000,3) as exec_time
-- FROM performance_schema.events_transactions_current trx JOIN performance_schema.events_statements_current stm USING (thread_id)
-- WHERE trx.state = 'ACTIVE' AND trx.timer_wait > 1000000000000 * 1 \G
