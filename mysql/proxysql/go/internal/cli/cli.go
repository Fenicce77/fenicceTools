package cli

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/model"
)

var ErrHelp = errors.New("help requested")

func Parse(args []string) (model.Config, error) {
	cfg := model.Config{Refresh: 5 * time.Second, Timeout: 5 * time.Second}
	explicitInteractive := false
	for index := 0; index < len(args); index++ {
		arg := args[index]
		name, value, hasValue := strings.Cut(arg, "=")
		nextValue := func() (string, error) {
			if hasValue {
				return value, nil
			}
			index++
			if index >= len(args) {
				return "", fmt.Errorf("option %s requires a value", name)
			}
			return args[index], nil
		}
		switch name {
		case "-h", "--help":
			return model.Config{}, ErrHelp
		case "--smoke-test":
			cfg.SmokeTest = true
		case "--login-path":
			item, err := nextValue()
			if err != nil {
				return cfg, err
			}
			if strings.TrimSpace(item) == "" {
				return cfg, errors.New("--login-path cannot be empty")
			}
			cfg.LoginPaths = append(cfg.LoginPaths, item)
		case "-r", "--refresh-time", "--query-timeout":
			item, err := nextValue()
			if err != nil {
				return cfg, err
			}
			duration, err := parseSeconds(item)
			if err != nil {
				return cfg, fmt.Errorf("%s: %w", name, err)
			}
			if name == "--query-timeout" {
				cfg.Timeout = duration
			} else {
				cfg.Refresh = duration
				explicitInteractive = true
			}
		case "-u", "--user-filter":
			item, err := nextValue()
			if err != nil {
				return cfg, err
			}
			cfg.UserFilter = item
			explicitInteractive = true
		case "-t", "--threshold":
			item, err := nextValue()
			if err != nil {
				return cfg, err
			}
			threshold, err := strconv.Atoi(item)
			if err != nil || threshold < 0 {
				return cfg, errors.New("threshold must be a non-negative integer")
			}
			cfg.Threshold = threshold
			explicitInteractive = true
		case "-o", "--output-file":
			item, err := nextValue()
			if err != nil {
				return cfg, err
			}
			cfg.OutputFile = item
			explicitInteractive = true
		default:
			return cfg, fmt.Errorf("unknown option %s", arg)
		}
	}
	if len(cfg.LoginPaths) == 0 {
		return cfg, errors.New("at least one --login-path is required")
	}
	if !cfg.SmokeTest && len(cfg.LoginPaths) != 1 {
		return cfg, errors.New("normal mode requires exactly one --login-path")
	}
	if cfg.SmokeTest && explicitInteractive {
		return cfg, errors.New("interactive display options cannot be used with --smoke-test")
	}
	return cfg, nil
}

func parseSeconds(value string) (time.Duration, error) {
	seconds, err := strconv.ParseFloat(value, 64)
	if err != nil || seconds <= 0 || math.IsInf(seconds, 0) || math.IsNaN(seconds) {
		return 0, errors.New("seconds must be greater than zero")
	}
	return time.Duration(seconds * float64(time.Second)), nil
}

func Help(program string) string {
	return fmt.Sprintf(`ProxySQL Ultimate Monitor (DBA Edition)

Usage: %s --login-path=NAME [OPTIONS]

  --login-path=NAME           MySQL login path; repeat only in smoke mode.
  -r, --refresh-time=SECONDS  Refresh interval, including fractions (default: 5).
  -u, --user-filter=REGEX     User regex; commas are alternatives.
  -t, --threshold=COUNT       Connection alert threshold (default: 0).
  -o, --output-file=FILE      Append clean, ANSI-free samples with data.
      --query-timeout=SECONDS SQL request timeout (default: 5).
      --smoke-test            Query all four views using SELECT statements only.
  -h, --help                  Show this help.

Examples:
  %s --login-path=proxysql_admin -r 0.5
  su - rmateos -c '%s --login-path=proxysql_admin -r 0.5'
`, program, program, program)
}
