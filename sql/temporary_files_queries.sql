SELECT *, sys.format_bytes(current_alloc) AS current_alloc FROM sys.x$memory_global_by_current_bytes where event_name like 'memory/temptable%';
show status where variable_name like '%files%';
show status where variable_name like 'Created%';
