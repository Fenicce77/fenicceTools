package transport

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newFakeSession(t *testing.T, state string) *Session {
	t.Helper()
	t.Setenv("GO_WANT_FAKE_MYSQL", "1")
	t.Setenv("FAKE_MYSQL_STATE_DIR", state)
	return New(Config{
		LoginPath:   "node01",
		MySQLBinary: os.Args[0],
		ArgsPrefix:  []string{"-test.run=TestFakeMySQLProcess"},
		QueueSize:   64,
		StderrLines: 3,
	})
}

func launchCount(t *testing.T, state string) int {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(state, "launches"))
	if err != nil {
		t.Fatal(err)
	}
	return len(strings.Fields(string(data)))
}

func TestMultipleRequestsUseOneChild(t *testing.T) {
	state := t.TempDir()
	session := newFakeSession(t, state)
	ctx := context.Background()
	if err := session.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	rows, err := session.Execute(ctx, "SELECT 'TEST_CONNECTIONS';", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := rows[0], "app\tclient\tbackend:3306\tappdb\t4"; got != want {
		t.Fatalf("row = %q, want %q", got, want)
	}
	if _, err := session.Execute(ctx, "SELECT 'TEST_SECOND_SAMPLE';", time.Second); err != nil {
		t.Fatal(err)
	}
	if got := launchCount(t, state); got != 1 {
		t.Fatalf("launches = %d, want 1", got)
	}
}

func TestTimeoutReconnectsOnce(t *testing.T) {
	t.Setenv("FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH", "1")
	state := t.TempDir()
	session := newFakeSession(t, state)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	t.Cleanup(func() { _ = session.Close() })
	rows, err := session.ExecuteWithRetry(ctx, "SELECT 'TEST_CONNECTIONS';", 500*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || launchCount(t, state) != 2 {
		t.Fatalf("rows=%v launches=%d", rows, launchCount(t, state))
	}
}

func TestCloseIsIdempotentAndRejectsRestart(t *testing.T) {
	session := newFakeSession(t, t.TempDir())
	if err := session.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if err := session.Start(context.Background()); err == nil {
		t.Fatal("Start after Close succeeded")
	}
}

func TestStderrIsBounded(t *testing.T) {
	t.Setenv("FAKE_MYSQL_STDERR_LINES", "20")
	session := newFakeSession(t, t.TempDir())
	t.Cleanup(func() { _ = session.Close() })
	if _, err := session.Execute(context.Background(), "SELECT @@version;", time.Second); err != nil {
		t.Fatal(err)
	}
	if got := len(session.Stderr()); got > 3 {
		t.Fatalf("stderr lines = %d, want <= 3", got)
	}
}

func TestClientKeepsBatchEscaping(t *testing.T) {
	session := New(Config{LoginPath: "node01"})
	args := session.commandArgs()
	if !contains(args, "--batch") || contains(args, "--raw") {
		t.Fatalf("unexpected mysql args: %v", args)
	}
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
