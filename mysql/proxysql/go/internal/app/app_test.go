package app

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/model"
)

type fakeSession struct {
	err       error
	closed    bool
	responses map[model.View][]string
}

func (s *fakeSession) ExecuteWithRetry(_ context.Context, sql string, _ time.Duration) ([]string, error) {
	if s.err != nil {
		return nil, s.err
	}
	switch {
	case strings.Contains(sql, "stats_mysql_connection_pool"):
		return s.responses[model.ViewBackend], nil
	case strings.Contains(sql, "stats_mysql_query_digest"):
		return s.responses[model.ViewDigest], nil
	case strings.Contains(sql, "info IS NOT NULL"):
		return s.responses[model.ViewQuery], nil
	default:
		return s.responses[model.ViewConn], nil
	}
}

func (s *fakeSession) Close() error {
	s.closed = true
	return nil
}

type fakeTerminal struct {
	answers  []string
	cleared  int
	restored bool
}

func (t *fakeTerminal) Prompt(string) (string, error) {
	answer := t.answers[0]
	t.answers = t.answers[1:]
	return answer, nil
}
func (t *fakeTerminal) Size() (int, int)                 { return 130, 24 }
func (t *fakeTerminal) Clear() error                     { t.cleared++; return nil }
func (t *fakeTerminal) Keys(context.Context) <-chan rune { return make(chan rune) }
func (t *fakeTerminal) Restore() error                   { t.restored = true; return nil }
func (t *fakeTerminal) MarkGeometryDirty()               {}

func newTestApp(t *testing.T, outputFile string) (*App, *fakeSession, *fakeTerminal) {
	t.Helper()
	session := &fakeSession{responses: map[model.View][]string{
		model.ViewConn:    {"app\tclient\tbackend:3306\tappdb\t6"},
		model.ViewQuery:   {"11\t10\tapp\tclient\tbackend:3306\t1200\tSELECT\\n* FROM t"},
		model.ViewDigest:  {"0x123\t8\t12000\t100\t4000\tSELECT col"},
		model.ViewBackend: {"__PXMON_POOL__", "10\tbackend:3306\tONLINE\t2\t3\t50\t0", "__PXMON_PING__", "backend\t2026-07-28\t500\t"},
	}}
	terminal := &fakeTerminal{}
	cfg := model.Config{
		LoginPaths: []string{"node01"}, Refresh: 5 * time.Second,
		Timeout: 5 * time.Second, OutputFile: outputFile,
	}
	return New(cfg, session, terminal, &bytes.Buffer{}), session, terminal
}

func TestViewPauseSortAndQuitTransitions(t *testing.T) {
	app, _, _ := newTestApp(t, "")
	app.HandleKey(context.Background(), 'v')
	if app.State.View != model.ViewQuery || app.State.Paused {
		t.Fatalf("state after v = %+v", app.State)
	}
	app.HandleKey(context.Background(), 'p')
	if !app.State.Paused {
		t.Fatal("p did not pause")
	}
	app.HandleKey(context.Background(), 'p')
	for _, want := range []model.View{model.ViewDigest, model.ViewBackend, model.ViewConn} {
		app.HandleKey(context.Background(), 'v')
		if app.State.View != want {
			t.Fatalf("view = %s, want %s", app.State.View, want)
		}
	}
	app.HandleKey(context.Background(), 's')
	if app.State.Sort != model.SortUser {
		t.Fatal("s did not change CONN sort")
	}
	app.HandleKey(context.Background(), 'q')
	if app.Running {
		t.Fatal("q did not stop")
	}
}

func TestFailedSamplePreservesLastOutput(t *testing.T) {
	app, session, _ := newTestApp(t, "")
	app.State.LastRendered = "last valid"
	session.err = errors.New("ProxySQL unavailable")
	if app.SampleCurrentView(context.Background()) {
		t.Fatal("failed sample reported success")
	}
	if !app.State.Stale || app.State.LastRendered != "last valid" {
		t.Fatalf("stale state = %+v", app.State)
	}
}

func TestPromptsAndCleanFreshLogging(t *testing.T) {
	path := filepath.Join(t.TempDir(), "monitor.log")
	app, session, terminal := newTestApp(t, path)
	terminal.answers = []string{"0.25", "9", "app,report"}
	app.HandleKey(context.Background(), 'r')
	app.HandleKey(context.Background(), 't')
	app.HandleKey(context.Background(), 'u')
	if app.Refresh != 250*time.Millisecond || app.Threshold != 9 || app.UserFilter != "app,report" {
		t.Fatalf("prompt values not applied: %+v", app)
	}
	if !app.SampleCurrentView(context.Background()) {
		t.Fatal("fresh sample failed")
	}
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(first, []byte("\x1b[")) {
		t.Fatal("log contains ANSI")
	}
	session.err = errors.New("down")
	app.SampleCurrentView(context.Background())
	second, _ := os.ReadFile(path)
	if !bytes.Equal(first, second) {
		t.Fatal("stale sample duplicated log")
	}
	if err := app.Close(); err != nil {
		t.Fatal(err)
	}
	if !session.closed || !terminal.restored {
		t.Fatal("Close did not release dependencies")
	}
}
