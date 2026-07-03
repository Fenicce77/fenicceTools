select @@innodb_lru_scan_depth,@@innodb_flushing_avg_loops,@@internal_tmp_mem_storage_engine;
SELECT *, sys.format_bytes(current_alloc) AS current_alloc FROM sys.x$memory_global_by_current_bytes where event_name like 'memory/temptable%';
show status where variable_name like '%files%';
show status where variable_name like 'Created%';

# change queries
set global innodb_lru_scan_depth=100;
set global innodb_flushing_avg_loops=5;
set global internal_tmp_mem_storage_engine = MEMORY;

#my.cnf changes 
innodb_lru_scan_depth=100;
innodb_flushing_avg_loops=5;
internal_tmp_mem_storage_engine = MEMORY;