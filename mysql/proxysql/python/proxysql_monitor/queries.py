from __future__ import annotations

from .models import SortMode, View

VERSION_SQL = "SELECT @@version;"
HOSTNAME_SQL = "SELECT @@hostname;"
BACKEND_POOL_MARKER = "__PXMON_POOL__"
BACKEND_PING_MARKER = "__PXMON_PING__"

_CONNECTIONS_SQL = """SELECT user, cli_host, COALESCE(srv_host, 'N/A'),
       COALESCE(db, 'N/A'), COUNT(*)
FROM stats.stats_mysql_processlist
WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql')
GROUP BY user, cli_host, srv_host, db
{order_clause};"""

QUERY_SQL = """SELECT SessionID, hostgroup, user, cli_host,
       COALESCE(srv_host, 'Pending'), time_ms, info
FROM stats.stats_mysql_processlist
WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql')
  AND info IS NOT NULL
  AND info != ''
ORDER BY time_ms DESC;"""

DIGEST_SQL = """SELECT digest, count_star, sum_time, min_time, max_time, digest_text
FROM stats.stats_mysql_query_digest
ORDER BY sum_time DESC
LIMIT 15;"""

BACKEND_SQL = f"""SELECT '{BACKEND_POOL_MARKER}';
SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR
FROM stats.stats_mysql_connection_pool
ORDER BY hostgroup, srv_host;
SELECT '{BACKEND_PING_MARKER}';
SELECT hostname, FROM_UNIXTIME(time_start_us / 1000 / 1000),
       ping_success_time_us, ping_error
FROM monitor.mysql_server_ping_log
ORDER BY time_start_us DESC
LIMIT 8;"""


def sql_for_view(view: View, sort_mode: SortMode = SortMode.CONN) -> str:
    """Return the read-only SQL payload for one monitor view."""
    if view is View.CONN:
        order = "ORDER BY COUNT(*) DESC" if sort_mode is SortMode.CONN else "ORDER BY user ASC"
        return _CONNECTIONS_SQL.format(order_clause=order)
    if view is View.QUERY:
        return QUERY_SQL
    if view is View.DIGEST:
        return DIGEST_SQL
    if view is View.BACKEND:
        return BACKEND_SQL
    raise ValueError(f"Unsupported view: {view!r}")
