package queries

import (
	"fmt"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/model"
)

const (
	VersionSQL        = "SELECT @@version;"
	HostnameSQL       = "SELECT @@hostname;"
	BackendPoolMarker = "__PXMON_POOL__"
	BackendPingMarker = "__PXMON_PING__"

	querySQL = `SELECT SessionID, hostgroup, user, cli_host,
       COALESCE(srv_host, 'Pending'), time_ms, info
FROM stats.stats_mysql_processlist
WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql')
  AND info IS NOT NULL
  AND info != ''
ORDER BY time_ms DESC;`

	digestSQL = `SELECT digest, count_star, sum_time, min_time, max_time, digest_text
FROM stats.stats_mysql_query_digest
ORDER BY sum_time DESC
LIMIT 15;`

	BackendSQL = `SELECT '__PXMON_POOL__';
SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, ConnOK, ConnERR
FROM stats.stats_mysql_connection_pool
ORDER BY hostgroup, srv_host;
SELECT '__PXMON_PING__';
SELECT hostname, FROM_UNIXTIME(time_start_us / 1000 / 1000),
       ping_success_time_us, ping_error
FROM monitor.mysql_server_ping_log
ORDER BY time_start_us DESC
LIMIT 8;`
)

func ForView(view model.View, sort model.SortMode) (string, error) {
	switch view {
	case model.ViewConn:
		order := "ORDER BY COUNT(*) DESC"
		if sort == model.SortUser {
			order = "ORDER BY user ASC"
		}
		return `SELECT user, cli_host, COALESCE(srv_host, 'N/A'),
       COALESCE(db, 'N/A'), COUNT(*)
FROM stats.stats_mysql_processlist
WHERE user NOT IN ('admin', 'radmin', 'monitor', 'proxysql')
GROUP BY user, cli_host, srv_host, db
` + order + ";", nil
	case model.ViewQuery:
		return querySQL, nil
	case model.ViewDigest:
		return digestSQL, nil
	case model.ViewBackend:
		return BackendSQL, nil
	default:
		return "", fmt.Errorf("unsupported view %q", view)
	}
}
