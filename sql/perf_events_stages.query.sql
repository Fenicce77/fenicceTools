-- desc performance_schema.events_stages_current;
-- +--------------------+------------------------------------------------+------+-----+---------+-------+
-- | Field              | Type                                           | Null | Key | Default | Extra |
-- +--------------------+------------------------------------------------+------+-----+---------+-------+
-- | THREAD_ID          | bigint unsigned                                | NO   | PRI | NULL    |       |
-- | EVENT_ID           | bigint unsigned                                | NO   | PRI | NULL    |       |
-- | END_EVENT_ID       | bigint unsigned                                | YES  |     | NULL    |       |
-- | EVENT_NAME         | varchar(128)                                   | NO   |     | NULL    |       |
-- | SOURCE             | varchar(64)                                    | YES  |     | NULL    |       |
-- | TIMER_START        | bigint unsigned                                | YES  |     | NULL    |       |
-- | TIMER_END          | bigint unsigned                                | YES  |     | NULL    |       |
-- | TIMER_WAIT         | bigint unsigned                                | YES  |     | NULL    |       |
-- | WORK_COMPLETED     | bigint unsigned                                | YES  |     | NULL    |       |
-- | WORK_ESTIMATED     | bigint unsigned                                | YES  |     | NULL    |       |
-- | NESTING_EVENT_ID   | bigint unsigned                                | YES  |     | NULL    |       |
-- | NESTING_EVENT_TYPE | enum('TRANSACTION','STATEMENT','STAGE','WAIT') | YES  |     | NULL    |       |
-- +--------------------+------------------------------------------------+------+-----+---------+-------+
-- 12 rows in set (0,11 sec)

-- events_stages_current
SELECT 
	THREAD_ID,EVENT_ID,EVENT_NAME, NESTING_EVENT_TYPE,
	ROUND(esc.TIMER_START/1000000000000,3) as TIMER_START_SECS,
	ROUND(esc.TIMER_END/1000000000000,3) as TIMER_START_SECS,
	ROUND(esc.TIMER_WAIT/1000000000000,3) as TIMER_WAIT_SECS,
	ROUND(esc.WORK_ESTIMATED/1000000000000,3) as RUNNING_SECS,
	FROM_UNIXTIME(ROUND(esc.TIMER_START/1000000000000,3) - to_seconds('1970-01-01 00:00:00')) as STARTED_AT,
	FROM_UNIXTIME(ROUND(esc.WORK_ESTIMATED/1000000000000,3) - to_seconds('1970-01-01 00:00:00')) as FINISH_ESTIMATION	
FROM performance_schema.events_stages_current esc;

-- desc performance_schema.events_stages_history;
-- +--------------------+------------------------------------------------+------+-----+---------+-------+
-- | Field              | Type                                           | Null | Key | Default | Extra |
-- +--------------------+------------------------------------------------+------+-----+---------+-------+
-- | THREAD_ID          | bigint unsigned                                | NO   | PRI | NULL    |       |
-- | EVENT_ID           | bigint unsigned                                | NO   | PRI | NULL    |       |
-- | END_EVENT_ID       | bigint unsigned                                | YES  |     | NULL    |       |
-- | EVENT_NAME         | varchar(128)                                   | NO   |     | NULL    |       |
-- | SOURCE             | varchar(64)                                    | YES  |     | NULL    |       |
-- | TIMER_START        | bigint unsigned                                | YES  |     | NULL    |       |
-- | TIMER_END          | bigint unsigned                                | YES  |     | NULL    |       |
-- | TIMER_WAIT         | bigint unsigned                                | YES  |     | NULL    |       |
-- | WORK_COMPLETED     | bigint unsigned                                | YES  |     | NULL    |       |
-- | WORK_ESTIMATED     | bigint unsigned                                | YES  |     | NULL    |       |
-- | NESTING_EVENT_ID   | bigint unsigned                                | YES  |     | NULL    |       |
-- | NESTING_EVENT_TYPE | enum('TRANSACTION','STATEMENT','STAGE','WAIT') | YES  |     | NULL    |       |
-- +--------------------+------------------------------------------------+------+-----+---------+-------+
-- 12 rows in set (0,27 sec)


SELECT 
	THREAD_ID,EVENT_ID,EVENT_NAME, NESTING_EVENT_TYPE,
	ROUND(esh.TIMER_START/1000000000000,3) as TIMER_START_SECS,
	ROUND(esh.TIMER_END/1000000000000,3) as TIMER_START_SECS,
	ROUND(esh.TIMER_WAIT/1000000000000,3) as TIMER_WAIT_SECS,
	ROUND(esh.WORK_ESTIMATED/1000000000000,3) as WORK_ESTIMATED_SECS,
	ROUND(esh.WORK_ESTIMATED/1000000000000,3) as RUNNING_SECS,
	FROM_UNIXTIME(ROUND(esh.TIMER_START/1000000000000,3) - to_seconds('1970-01-01 00:00:00')) as STARTED_AT,
	FROM_UNIXTIME(ROUND(esh.WORK_ESTIMATED/1000000000000,3) - to_seconds('1970-01-01 00:00:00')) as FINISH_ESTIMATION
FROM performance_schema.events_stages_history esh;