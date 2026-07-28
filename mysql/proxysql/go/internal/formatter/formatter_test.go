package formatter

import (
	"strings"
	"testing"
)

func TestConnectionDelta(t *testing.T) {
	previous, err := ParseConnections([]string{"app\tclient\tbackend:3306\tappdb\t4"})
	if err != nil {
		t.Fatal(err)
	}
	current, err := ParseConnections([]string{"app\tclient\tbackend:3306\tappdb\t6"})
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := FormatConnections(current, previous, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rendered.Clean, "+2") || rendered.RowCount != 1 {
		t.Fatalf("unexpected render: %+v", rendered)
	}
}

func TestQuerySanitizationAndColor(t *testing.T) {
	rows, err := ParseQueries([]string{"11\t10\tapp\tclient\tbackend:3306\t1200\tSELECT\\n*\\tFROM t"})
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := FormatQueries(rows, "", 130)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rendered.Clean, "SELECT * FROM t") ||
		!strings.Contains(rendered.Colored, "\x1b[") {
		t.Fatalf("unexpected render: %+v", rendered)
	}
}

func TestBackendParsing(t *testing.T) {
	rows, err := ParseBackend([]string{
		"__PXMON_POOL__",
		"10\tbackend:3306\tONLINE\t2\t3\t50\t1",
		"__PXMON_PING__",
		"backend\t2026-07-28 12:00:00\t500\t",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows.Pool) != 1 || len(rows.Ping) != 1 || *rows.Ping[0].SuccessUS != 500 {
		t.Fatalf("unexpected backend rows: %+v", rows)
	}
}

func TestNullPingSuccessIsOptional(t *testing.T) {
	rows, err := ParseBackend([]string{
		"__PXMON_POOL__",
		"__PXMON_PING__",
		"backend\t2026-07-28 12:00:00\tNULL\tconnection refused",
	})
	if err != nil {
		t.Fatal(err)
	}
	if rows.Ping[0].SuccessUS != nil {
		t.Fatalf("success = %v, want nil", rows.Ping[0].SuccessUS)
	}
}

func TestMalformedRowsFailAndEmptyRowsPass(t *testing.T) {
	if _, err := ParseConnections(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := ParseQueries([]string{"bad"}); err == nil {
		t.Fatal("malformed query succeeded")
	}
	if _, err := ParseBackend([]string{"pool row"}); err == nil {
		t.Fatal("backend without markers succeeded")
	}
}

func TestFilterAlternationAndDigestWidth(t *testing.T) {
	filter, err := CompileUserFilter("app,report.*")
	if err != nil {
		t.Fatal(err)
	}
	if !filter.MatchString("APP") || !filter.MatchString("reporting") || filter.MatchString("batch") {
		t.Fatal("unexpected filter behavior")
	}
	rows, err := ParseDigests([]string{
		"0x123\t8\t12000\t100\t4000\t" + strings.Repeat("SELECT col FROM table ", 20),
	})
	if err != nil {
		t.Fatal(err)
	}
	rendered := FormatDigests(rows, 110)
	for _, line := range strings.Split(rendered.Clean, "\n") {
		if len(line) > 110 {
			t.Fatalf("line length = %d, want <= 110", len(line))
		}
	}
}

func TestBashConnWidthsGlobalDeltaAndControlNeutralization(t *testing.T) {
	previous, _ := ParseConnections([]string{"app\tclient\tbackend:3306\tappdb\t4"})
	current, _ := ParseConnections([]string{"app\tclient\tbackend:3306\tappdb\t6"})
	rendered, err := FormatConnections(current, previous, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(rendered.Clean, "\n")
	if !strings.Contains(lines[len(lines)-1], "GLOBAL TOTALS") ||
		!strings.Contains(lines[len(lines)-1], "+2") {
		t.Fatalf("missing global delta: %q", lines[len(lines)-1])
	}
	if !strings.HasPrefix(lines[0], "USER                 | SOURCE (Cli)") {
		t.Fatalf("unexpected Bash widths: %q", lines[0])
	}

	queries, err := ParseQueries([]string{
		"11\t10\tapp\tclient\tbackend:3306\t1\tSELECT \x1b[31m bad\x7f",
	})
	if err != nil {
		t.Fatal(err)
	}
	queryView, err := FormatQueries(queries, "", 130)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(queryView.Clean, "\x1b") || strings.Contains(queryView.Clean, "\x7f") {
		t.Fatalf("clean output contains terminal controls: %q", queryView.Clean)
	}
}
