package app

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/model"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/queries"
)

type smokeSession struct {
	loginPath string
	responses map[model.View][]string
	closed    bool
	closeErr  error
}

func (s *smokeSession) ExecuteWithRetry(_ context.Context, sql string, _ time.Duration) ([]string, error) {
	switch {
	case sql == queries.VersionSQL:
		return []string{"2.7.3"}, nil
	case sql == queries.HostnameSQL:
		return []string{s.loginPath}, nil
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

func (s *smokeSession) Close() error {
	s.closed = true
	return s.closeErr
}

func smokeResponses() map[model.View][]string {
	return map[model.View][]string{
		model.ViewConn:    {"app\tclient\tbackend:3306\tappdb\t6"},
		model.ViewQuery:   {"11\t10\tapp\tclient\tbackend:3306\t1200\tSELECT\\n* FROM t"},
		model.ViewDigest:  {"0x123\t8\t12000\t100\t4000\tSELECT col"},
		model.ViewBackend: {"__PXMON_POOL__", "10\tbackend:3306\tONLINE\t2\t3\t50\t0", "__PXMON_PING__", "backend\t2026-07-28\t500\t"},
	}
}

func TestSmokeNodeViewOrderAndCleanup(t *testing.T) {
	var sessions []*smokeSession
	factory := func(loginPath string) Session {
		session := &smokeSession{loginPath: loginPath, responses: smokeResponses()}
		sessions = append(sessions, session)
		return session
	}
	cfg := model.Config{
		LoginPaths: []string{"node01", "node02"}, SmokeTest: true, Timeout: time.Second,
	}
	results := RunSmokeWithResolver(
		context.Background(), cfg, factory,
		func(_ context.Context, loginPath string, _ Session) (string, error) {
			return loginPath, nil
		},
	)
	want := []string{
		"node01/CONN", "node01/QUERY", "node01/DIGEST", "node01/BACKEND",
		"node02/CONN", "node02/QUERY", "node02/DIGEST", "node02/BACKEND",
	}
	var got []string
	for _, result := range results {
		got = append(got, result.LoginPath+"/"+string(result.View))
		if !result.Success {
			t.Fatalf("unexpected failure: %+v", result)
		}
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("order = %v, want %v", got, want)
	}
	for _, session := range sessions {
		if !session.closed {
			t.Fatal("session was not closed")
		}
	}
}

func TestSmokeEmptyViewsPassAndMalformedViewDoesNotStop(t *testing.T) {
	responses := map[model.View][]string{
		model.ViewConn: nil, model.ViewQuery: {"bad"}, model.ViewDigest: nil,
		model.ViewBackend: {"__PXMON_POOL__", "__PXMON_PING__"},
	}
	results := RunSmokeWithResolver(
		context.Background(),
		model.Config{LoginPaths: []string{"node01"}, SmokeTest: true, Timeout: time.Second},
		func(loginPath string) Session {
			return &smokeSession{loginPath: loginPath, responses: responses}
		},
		func(_ context.Context, loginPath string, _ Session) (string, error) {
			return loginPath, nil
		},
	)
	if !results[0].Success || results[1].Success || !results[2].Success || !results[3].Success {
		t.Fatalf("unexpected results: %+v", results)
	}
}

func TestSmokeMissingBackendMarkersFails(t *testing.T) {
	responses := smokeResponses()
	responses[model.ViewBackend] = nil
	results := RunSmokeWithResolver(
		context.Background(),
		model.Config{LoginPaths: []string{"node01"}, SmokeTest: true, Timeout: time.Second},
		func(loginPath string) Session {
			return &smokeSession{loginPath: loginPath, responses: responses}
		},
		func(_ context.Context, loginPath string, _ Session) (string, error) {
			return loginPath, nil
		},
	)
	if results[3].Success {
		t.Fatal("missing backend markers succeeded")
	}
}

func TestSmokeCleanupFailureFailsNode(t *testing.T) {
	results := RunSmokeWithResolver(
		context.Background(),
		model.Config{LoginPaths: []string{"node01"}, SmokeTest: true, Timeout: time.Second},
		func(loginPath string) Session {
			return &smokeSession{
				loginPath: loginPath, responses: smokeResponses(),
				closeErr: errors.New("cleanup failed"),
			}
		},
		func(_ context.Context, loginPath string, _ Session) (string, error) {
			return loginPath, nil
		},
	)
	for _, result := range results {
		if result.Success || !strings.Contains(result.Error, "cleanup failed") {
			t.Fatalf("cleanup failure not propagated: %+v", result)
		}
	}
}
