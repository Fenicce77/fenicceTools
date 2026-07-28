package cli

import (
	"strings"
	"testing"
	"time"
)

func TestParseNormalMode(t *testing.T) {
	cfg, err := Parse([]string{
		"--login-path=proxysql_admin",
		"--refresh-time=0.5",
		"--user-filter=app,report",
		"--threshold=12",
		"--output-file=/tmp/proxysql.log",
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.Join(cfg.LoginPaths, ","), "proxysql_admin"; got != want {
		t.Fatalf("login paths = %q, want %q", got, want)
	}
	if cfg.Refresh != 500*time.Millisecond ||
		cfg.UserFilter != "app,report" ||
		cfg.Threshold != 12 ||
		cfg.OutputFile != "/tmp/proxysql.log" ||
		cfg.Timeout != 5*time.Second {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}

func TestParseSmokeRepeatedLoginPaths(t *testing.T) {
	cfg, err := Parse([]string{
		"--smoke-test",
		"--login-path=node01",
		"--login-path=node02",
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.Join(cfg.LoginPaths, ","), "node01,node02"; got != want {
		t.Fatalf("login paths = %q, want %q", got, want)
	}
}

func TestParseRejectsInvalidValues(t *testing.T) {
	tests := [][]string{
		{},
		{"--login-path=node01", "--refresh-time=0"},
		{"--login-path=node01", "--threshold=-1"},
		{"--login-path=node01", "--login-path=node02"},
		{"--smoke-test", "--login-path=node01", "--refresh-time=1"},
	}
	for _, args := range tests {
		if _, err := Parse(args); err == nil {
			t.Fatalf("Parse(%v) succeeded, want error", args)
		}
	}
}

func TestHelpContainsOptionsAndExample(t *testing.T) {
	help := Help("proxysql-monitor")
	for _, value := range []string{"--login-path", "--refresh-time", "--smoke-test", "rmateos"} {
		if !strings.Contains(help, value) {
			t.Fatalf("help missing %q", value)
		}
	}
}
