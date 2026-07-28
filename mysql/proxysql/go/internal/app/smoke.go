package app

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/formatter"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/model"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/queries"
)

type SessionFactory func(loginPath string) Session
type HostResolver func(context.Context, string, Session) (string, error)

func RunSmoke(
	ctx context.Context,
	config model.Config,
	factory SessionFactory,
) []model.SmokeResult {
	return RunSmokeWithResolver(ctx, config, factory, ResolveDisplayHost)
}

func RunSmokeWithResolver(
	ctx context.Context,
	config model.Config,
	factory SessionFactory,
	resolver HostResolver,
) []model.SmokeResult {
	views := []model.View{model.ViewConn, model.ViewQuery, model.ViewDigest, model.ViewBackend}
	results := make([]model.SmokeResult, 0, len(config.LoginPaths)*len(views))
	for _, loginPath := range config.LoginPaths {
		nodeStart := len(results)
		session := factory(loginPath)
		version, err := session.ExecuteWithRetry(ctx, queries.VersionSQL, config.Timeout)
		if err == nil && len(version) == 0 {
			err = errors.New("ProxySQL returned an empty version")
		}
		if err == nil {
			_, err = resolver(ctx, loginPath, session)
		}
		if err != nil {
			for _, view := range views {
				results = append(results, model.SmokeResult{
					LoginPath: loginPath, View: view, Success: false, Error: err.Error(),
				})
			}
			if closeErr := session.Close(); closeErr != nil {
				for index := nodeStart; index < len(results); index++ {
					results[index].Success = false
					results[index].Error = errors.Join(err, closeErr).Error()
				}
			}
			continue
		}

		for _, view := range views {
			started := time.Now()
			sql, queryErr := queries.ForView(view, model.SortConn)
			var raw []string
			if queryErr == nil {
				raw, queryErr = session.ExecuteWithRetry(ctx, sql, config.Timeout)
			}
			rows := 0
			if queryErr == nil {
				rows, queryErr = smokeRowCount(view, raw)
			}
			result := model.SmokeResult{
				LoginPath: loginPath, View: view, Rows: rows,
				Elapsed: time.Since(started), Success: queryErr == nil,
			}
			if queryErr != nil {
				result.Error = queryErr.Error()
			}
			results = append(results, result)
		}
		if closeErr := session.Close(); closeErr != nil {
			for index := nodeStart; index < len(results); index++ {
				results[index].Success = false
				results[index].Error = closeErr.Error()
			}
		}
	}
	return results
}

func smokeRowCount(view model.View, raw []string) (int, error) {
	switch view {
	case model.ViewConn:
		rows, err := formatter.ParseConnections(raw)
		return len(rows), err
	case model.ViewQuery:
		rows, err := formatter.ParseQueries(raw)
		return len(rows), err
	case model.ViewDigest:
		rows, err := formatter.ParseDigests(raw)
		return len(rows), err
	case model.ViewBackend:
		hasPool, hasPing := false, false
		for _, line := range raw {
			hasPool = hasPool || line == queries.BackendPoolMarker
			hasPing = hasPing || line == queries.BackendPingMarker
		}
		if !hasPool || !hasPing {
			return 0, errors.New("BACKEND payload is missing section markers")
		}
		rows, err := formatter.ParseBackend(raw)
		return len(rows.Pool) + len(rows.Ping), err
	default:
		return 0, errors.New("unsupported smoke view")
	}
}

func ResolveDisplayHost(ctx context.Context, loginPath string, session Session) (string, error) {
	binary := os.Getenv("MYSQL_CONFIG_EDITOR_BIN")
	if binary == "" {
		binary = "mysql_config_editor"
	}
	resolveContext, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	output, err := exec.CommandContext(
		resolveContext, binary, "print", "--login-path="+loginPath,
	).Output()
	if err == nil {
		hostPattern := regexp.MustCompile(`(?m)^\s*host\s*=\s*(.+?)\s*$`)
		if match := hostPattern.FindSubmatch(output); len(match) == 2 {
			return strings.TrimSpace(string(match[1])), nil
		}
	}
	rows, queryErr := session.ExecuteWithRetry(ctx, queries.HostnameSQL, 2*time.Second)
	if queryErr != nil {
		return "", queryErr
	}
	if len(rows) == 0 {
		return "Unknown", nil
	}
	return rows[0], nil
}
