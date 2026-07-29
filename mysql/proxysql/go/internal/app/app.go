package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/formatter"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/model"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/queries"
)

const (
	appBold    = "\x1b[1m"
	appBlue    = "\x1b[1;34m"
	appGreen   = "\x1b[1;32m"
	appYellow  = "\x1b[1;33m"
	appRed     = "\x1b[1;31m"
	appMagenta = "\x1b[1;35m"
	appReset   = "\x1b[0m"
)

type Session interface {
	ExecuteWithRetry(context.Context, string, time.Duration) ([]string, error)
	Close() error
}

type Terminal interface {
	Prompt(context.Context, string) (string, error)
	Size() (int, int)
	Clear() error
	Keys(context.Context) <-chan rune
	Restore() error
	Stop() error
	MarkGeometryDirty()
}

type App struct {
	Config       model.Config
	State        model.State
	Refresh      time.Duration
	UserFilter   string
	Threshold    int
	Running      bool
	DisplayHost  string
	ProxyVersion string

	session     Session
	terminal    Terminal
	output      io.Writer
	lastColored string
	lastRows    int
	closeOnce   sync.Once
	closeErr    error
	wallClock   func() time.Time
}

func New(config model.Config, session Session, terminal Terminal, output io.Writer) *App {
	return &App{
		Config: config, State: model.NewState(), Refresh: config.Refresh,
		UserFilter: config.UserFilter, Threshold: config.Threshold, Running: true,
		DisplayHost: config.LoginPaths[0], ProxyVersion: "Unknown",
		session: session, terminal: terminal, output: output, wallClock: time.Now,
	}
}

func interactiveLegend() string {
	return fmt.Sprintf(
		"%sInteractive Options:%s\n"+
			" [%sv%s] %sToggle View%s (Conn/Query/Digest/Backend) | "+
			"[%sr%s] %sRefresh%s | [%ss%s] %sSort%s | [%sp%s] %sPause%s\n"+
			" [%su%s] %sFilter%s | [%st%s] %sThreshold%s | [%sq%s] %sQuit%s",
		appBold, appReset,
		appMagenta, appReset, appBlue, appReset,
		appMagenta, appReset, appGreen, appReset,
		appMagenta, appReset, appGreen, appReset,
		appMagenta, appReset, appYellow, appReset,
		appMagenta, appReset, appGreen, appReset,
		appMagenta, appReset, appRed, appReset,
		appMagenta, appReset, appRed, appReset,
	)
}

func (a *App) SampleCurrentView(ctx context.Context) bool {
	sql, err := queries.ForView(a.State.View, a.State.Sort)
	if err != nil {
		a.markStale(err)
		return false
	}
	raw, err := a.session.ExecuteWithRetry(ctx, sql, a.Config.Timeout)
	if err != nil {
		a.markStale(err)
		return false
	}
	width, _ := a.terminal.Size()
	var rendered model.RenderedView
	switch a.State.View {
	case model.ViewConn:
		rows, parseErr := formatter.ParseConnections(raw)
		if parseErr != nil {
			a.markStale(parseErr)
			return false
		}
		rendered, err = formatter.FormatConnections(
			rows, a.State.PreviousConnections, a.Threshold, a.UserFilter,
		)
		if err == nil {
			a.State.PreviousConnections = rows
		}
	case model.ViewQuery:
		rows, parseErr := formatter.ParseQueries(raw)
		if parseErr != nil {
			err = parseErr
		} else {
			rendered, err = formatter.FormatQueries(rows, a.UserFilter, width)
		}
	case model.ViewDigest:
		rows, parseErr := formatter.ParseDigests(raw)
		if parseErr != nil {
			err = parseErr
		} else {
			rendered = formatter.FormatDigests(rows, width)
		}
	case model.ViewBackend:
		rows, parseErr := formatter.ParseBackend(raw)
		if parseErr != nil {
			err = parseErr
		} else {
			rendered = formatter.FormatBackend(rows)
		}
	}
	if err != nil {
		a.markStale(err)
		return false
	}
	a.State.Stale = false
	a.State.LastError = ""
	a.State.LastRendered = rendered.Clean
	a.lastColored = rendered.Colored
	a.lastRows = rendered.RowCount
	if err := a.Log(rendered); err != nil {
		a.markStale(err)
		return false
	}
	return true
}

func (a *App) HandleKey(ctx context.Context, key rune) {
	switch key {
	case 'q', 'Q', rune(3):
		a.Running = false
	case 'v', 'V':
		views := []model.View{model.ViewConn, model.ViewQuery, model.ViewDigest, model.ViewBackend}
		for index, view := range views {
			if view == a.State.View {
				a.State.View = views[(index+1)%len(views)]
				break
			}
		}
		a.State.Paused = false
		if a.State.View == model.ViewConn {
			a.State.PreviousConnections = nil
		}
	case 's', 'S':
		a.State.Paused = false
		if a.State.View == model.ViewConn {
			if a.State.Sort == model.SortConn {
				a.State.Sort = model.SortUser
			} else {
				a.State.Sort = model.SortConn
			}
			a.State.PreviousConnections = nil
		}
	case 'p', 'P':
		a.State.Paused = !a.State.Paused
	case 'r', 'R':
		value, err := a.terminal.Prompt(ctx, "Enter new refresh time (seconds, e.g. 0.5): ")
		if err == nil {
			if seconds, parseErr := strconv.ParseFloat(value, 64); parseErr == nil && seconds > 0 {
				a.Refresh = time.Duration(seconds * float64(time.Second))
			}
		}
	case 't', 'T':
		value, err := a.terminal.Prompt(ctx, "Enter new connection threshold: ")
		if err == nil {
			if threshold, parseErr := strconv.Atoi(value); parseErr == nil && threshold >= 0 {
				a.Threshold = threshold
			}
		}
	case 'u', 'U':
		value, err := a.terminal.Prompt(ctx, "Enter new user filter (empty to disable): ")
		if err == nil {
			expression := strings.ReplaceAll(value, ",", "|")
			if _, compileErr := regexp.Compile(expression); compileErr == nil {
				a.UserFilter = value
			}
		}
	}
	_ = ctx
}

func (a *App) Render() error {
	if err := a.terminal.Clear(); err != nil {
		return err
	}
	flags := ""
	if a.State.Paused {
		flags += " [PAUSED]"
	}
	if a.State.Stale {
		flags += " [STALE: " + formatter.Sanitize(a.State.LastError) + "]"
	}
	header := fmt.Sprintf(
		"ProxySQL Monitor | Server: %s | Version: %s | Mode: %s | Refresh: %s%s\n",
		formatter.Sanitize(a.DisplayHost), formatter.Sanitize(a.ProxyVersion),
		a.State.View, a.Refresh, flags,
	)
	filterLine := ""
	if a.UserFilter != "" {
		filterLine = "Filter: " + formatter.Sanitize(a.UserFilter)
	}
	if a.Threshold > 0 {
		if filterLine != "" {
			filterLine += " | "
		}
		filterLine += fmt.Sprintf("Threshold: >= %d conn", a.Threshold)
	}
	if filterLine != "" {
		filterLine += "\n"
	}
	body := a.lastColored
	if body == "" {
		body = "No active data to display."
	}
	_, err := fmt.Fprintf(
		a.output, "%s%s%s\n%s\n\n%s\n",
		header, filterLine, strings.Repeat("=", 110), body, interactiveLegend(),
	)
	return err
}

func (a *App) Log(rendered model.RenderedView) error {
	if a.Config.OutputFile == "" || rendered.RowCount == 0 {
		return nil
	}
	file, err := os.OpenFile(a.Config.OutputFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = fmt.Fprintf(file, "=== %s | MODE: %s ===\n%s\n",
		a.wallClock().Format("2006-01-02 15:04:05"), a.State.View, rendered.Clean)
	return err
}

func (a *App) Run(ctx context.Context) error {
	keys := a.terminal.Keys(ctx)
	timer := time.NewTimer(0)
	defer timer.Stop()
	for a.Running {
		select {
		case <-ctx.Done():
			return nil
		case key, ok := <-keys:
			if !ok {
				keys = nil
				continue
			}
			a.HandleKey(ctx, key)
			if key == 'v' || key == 'V' || key == 's' || key == 'S' {
				if !a.State.Paused {
					a.SampleCurrentView(ctx)
				}
			}
			if err := a.Render(); err != nil {
				return err
			}
		case <-timer.C:
			if !a.State.Paused {
				a.SampleCurrentView(ctx)
			}
			if err := a.Render(); err != nil {
				return err
			}
			timer.Reset(a.Refresh)
		}
	}
	return nil
}

func (a *App) Close() error {
	a.closeOnce.Do(func() {
		a.closeErr = errors.Join(a.terminal.Stop(), a.terminal.Restore(), a.session.Close())
	})
	return a.closeErr
}

func (a *App) markStale(err error) {
	a.State.Stale = true
	a.State.LastError = err.Error()
}
