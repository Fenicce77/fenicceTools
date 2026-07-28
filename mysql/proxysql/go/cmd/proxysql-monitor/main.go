package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/app"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/cli"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/terminal"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/transport"
)

const (
	green = "\x1b[1;32m"
	red   = "\x1b[1;31m"
	reset = "\x1b[0m"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	config, err := cli.Parse(args)
	if errors.Is(err, cli.ErrHelp) {
		fmt.Print(cli.Help(os.Args[0]))
		return 0
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "%sError: %v%s\n\n%s", red, err, reset, cli.Help(os.Args[0]))
		return 2
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	factory := func(loginPath string) app.Session {
		return transport.New(transport.Config{LoginPath: loginPath})
	}
	if config.SmokeTest {
		results := app.RunSmoke(ctx, config, factory)
		success := len(results) > 0
		for _, result := range results {
			status, color := "PASS", green
			if !result.Success {
				status, color, success = "FAIL", red, false
			}
			errorText := ""
			if result.Error != "" {
				errorText = " | " + result.Error
			}
			fmt.Printf(
				"%s%s%s | %-28s | %-7s | rows=%-5d | %8.1f ms%s\n",
				color, status, reset, result.LoginPath, result.View, result.Rows,
				float64(result.Elapsed.Microseconds())/1000, errorText,
			)
		}
		if success {
			return 0
		}
		return 1
	}

	controller := terminal.New(os.Stdin, os.Stdout)
	if err := controller.Enter(); err != nil {
		fmt.Fprintf(os.Stderr, "%sError: %v%s\n", red, err, reset)
		return 1
	}
	session := factory(config.LoginPaths[0])
	monitor := app.New(config, session, controller, os.Stdout)
	runErr := monitor.Run(ctx)
	closeErr := monitor.Close()
	if err := errors.Join(runErr, closeErr); err != nil {
		fmt.Fprintf(os.Stderr, "%sError: %v%s\n", red, err, reset)
		return 1
	}
	return 0
}
