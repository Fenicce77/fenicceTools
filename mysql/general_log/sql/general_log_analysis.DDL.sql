CREATE TABLE IF NOT EXISTS general_log_analysis (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    thread_id BIGINT UNSIGNED NOT NULL,
    user_host VARCHAR(255) NOT NULL,
    server_id INT UNSIGNED NOT NULL,
    command_type VARCHAR(64) NOT NULL,
    argument MEDIUMTEXT NOT NULL,
    event_time datetime NOT NULL,    
    PRIMARY KEY (id),
    KEY `IDX_thread_id_user_commandt_event_time` (`thread_id`,`user_host`,`command_type`,`event_time`),
    KEY `IDX_user_commandt_event_time` (`user_host`,`command_type`,`event_time`),
    KEY `IDX_thread_id_event_time` (`thread_id`,`event_time`),
    KEY `IDX_user_host_event_time` (`user_host`,`event_time`),
    KEY `IDX_event_time` (`event_time`),
    KEY `IDX_thread_serverid` (`thread_id`,`server_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;