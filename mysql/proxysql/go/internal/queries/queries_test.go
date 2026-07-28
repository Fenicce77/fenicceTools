package queries

import (
	"strings"
	"testing"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/model"
)

func TestBackendSQLIsReadOnlyAndContainsBothSources(t *testing.T) {
	if !strings.Contains(BackendSQL, "stats.stats_mysql_connection_pool") ||
		!strings.Contains(BackendSQL, "monitor.mysql_server_ping_log") {
		t.Fatal("backend SQL does not contain both sources")
	}
	if strings.Contains(strings.ToUpper(BackendSQL), "UPDATE ") {
		t.Fatal("backend SQL is not read-only")
	}
}

func TestConnSortChangesOrderClause(t *testing.T) {
	byConn, err := ForView(model.ViewConn, model.SortConn)
	if err != nil {
		t.Fatal(err)
	}
	byUser, err := ForView(model.ViewConn, model.SortUser)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(byConn, "ORDER BY COUNT(*) DESC") {
		t.Fatal("connection sort missing")
	}
	if !strings.Contains(byUser, "ORDER BY user ASC") {
		t.Fatal("user sort missing")
	}
}
