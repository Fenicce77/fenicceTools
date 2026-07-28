package formatter

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/model"
	"github.com/Fenicce77/fenicceTools/mysql/proxysql/go/internal/queries"
)

const (
	bold   = "\x1b[1m"
	red    = "\x1b[1;31m"
	green  = "\x1b[1;32m"
	yellow = "\x1b[1;33m"
	cyan   = "\x1b[1;36m"
	reset  = "\x1b[0m"
)

func parseInt(value, field string) (int, error) {
	number, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("invalid %s %q: %w", field, value, err)
	}
	return number, nil
}

func Sanitize(value string) string {
	replacer := strings.NewReplacer(
		`\n`, " ", `\r`, " ", `\t`, " ",
		"\n", " ", "\r", " ", "\t", " ",
	)
	return strings.TrimSpace(replacer.Replace(value))
}

func truncate(value string, width int) string {
	if width <= 0 {
		return ""
	}
	if utf8.RuneCountInString(value) <= width {
		return value
	}
	return string([]rune(value)[:width])
}

func CompileUserFilter(value string) (*regexp.Regexp, error) {
	if value == "" {
		value = ".*"
	} else {
		value = strings.ReplaceAll(value, ",", "|")
	}
	filter, err := regexp.Compile("(?i)" + value)
	if err != nil {
		return nil, fmt.Errorf("invalid user filter regex: %w", err)
	}
	return filter, nil
}

func ParseConnections(lines []string) ([]model.ConnectionRow, error) {
	rows := make([]model.ConnectionRow, 0, len(lines))
	for _, line := range lines {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 5 {
			return nil, fmt.Errorf("malformed CONN row %q", line)
		}
		connections, err := parseInt(fields[4], "connections")
		if err != nil {
			return nil, err
		}
		rows = append(rows, model.ConnectionRow{
			User: fields[0], ClientHost: fields[1], ServerHost: fields[2],
			Schema: fields[3], Connections: connections,
		})
	}
	return rows, nil
}

func ParseQueries(lines []string) ([]model.QueryRow, error) {
	rows := make([]model.QueryRow, 0, len(lines))
	for _, line := range lines {
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, "\t", 7)
		if len(fields) != 7 {
			return nil, fmt.Errorf("malformed QUERY row %q", line)
		}
		timeMS, err := parseInt(fields[5], "time_ms")
		if err != nil {
			return nil, err
		}
		rows = append(rows, model.QueryRow{
			SessionID: fields[0], Hostgroup: fields[1], User: fields[2],
			ClientHost: fields[3], ServerHost: fields[4], TimeMS: timeMS,
			Query: Sanitize(fields[6]),
		})
	}
	return rows, nil
}

func ParseDigests(lines []string) ([]model.DigestRow, error) {
	rows := make([]model.DigestRow, 0, len(lines))
	for _, line := range lines {
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, "\t", 6)
		if len(fields) != 6 {
			return nil, fmt.Errorf("malformed DIGEST row %q", line)
		}
		values := make([]int, 4)
		names := []string{"count_star", "sum_time", "min_time", "max_time"}
		for index := range values {
			number, err := parseInt(fields[index+1], names[index])
			if err != nil {
				return nil, err
			}
			values[index] = number
		}
		rows = append(rows, model.DigestRow{
			Digest: fields[0], Count: values[0], SumTime: values[1],
			MinTime: values[2], MaxTime: values[3], Query: Sanitize(fields[5]),
		})
	}
	return rows, nil
}

func ParseBackend(lines []string) (model.BackendRows, error) {
	if len(lines) == 0 {
		return model.BackendRows{}, nil
	}
	poolIndex, pingIndex := -1, -1
	for index, line := range lines {
		switch line {
		case queries.BackendPoolMarker:
			poolIndex = index
		case queries.BackendPingMarker:
			pingIndex = index
		}
	}
	if poolIndex < 0 || pingIndex < 0 || poolIndex >= pingIndex {
		return model.BackendRows{}, errorsNew("BACKEND payload is missing or has invalid section markers")
	}
	var result model.BackendRows
	for _, line := range lines[poolIndex+1 : pingIndex] {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 7 {
			return model.BackendRows{}, fmt.Errorf("malformed BACKEND pool row %q", line)
		}
		values := make([]int, 4)
		for index, name := range []string{"ConnUsed", "ConnFree", "ConnOK", "ConnERR"} {
			number, err := parseInt(fields[index+3], name)
			if err != nil {
				return model.BackendRows{}, err
			}
			values[index] = number
		}
		result.Pool = append(result.Pool, model.PoolRow{
			Hostgroup: fields[0], ServerHost: fields[1], Status: fields[2],
			ConnUsed: values[0], ConnFree: values[1], ConnOK: values[2], ConnErr: values[3],
		})
	}
	for _, line := range lines[pingIndex+1:] {
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, "\t", 4)
		if len(fields) != 4 {
			return model.BackendRows{}, fmt.Errorf("malformed BACKEND ping row %q", line)
		}
		var success *int
		if fields[2] != "" {
			number, err := parseInt(fields[2], "ping_success_time_us")
			if err != nil {
				return model.BackendRows{}, err
			}
			success = &number
		}
		result.Ping = append(result.Ping, model.PingRow{
			Hostname: fields[0], LastPing: fields[1], SuccessUS: success,
			Error: Sanitize(fields[3]),
		})
	}
	return result, nil
}

func errorsNew(message string) error {
	return fmt.Errorf("%s", message)
}

func render(cleanLines, coloredLines []string, count int) model.RenderedView {
	return model.RenderedView{
		Clean: strings.Join(cleanLines, "\n"), Colored: strings.Join(coloredLines, "\n"),
		RowCount: count,
	}
}

func FormatConnections(
	rows, previous []model.ConnectionRow,
	threshold int,
	userFilter string,
) (model.RenderedView, error) {
	filter, err := CompileUserFilter(userFilter)
	if err != nil {
		return model.RenderedView{}, err
	}
	type key struct{ user, client, server, schema string }
	old := make(map[key]int, len(previous))
	for _, row := range previous {
		old[key{row.User, row.ClientHost, row.ServerHost, row.Schema}] = row.Connections
	}
	header := fmt.Sprintf("%-15s %-20s %-25s %-15s %6s %7s",
		"USER", "SOURCE (Cli)", "BACKEND (Srv)", "SCHEMA", "CONN", "DELTA")
	clean, colored := []string{header}, []string{bold + header + reset}
	count := 0
	for _, row := range rows {
		if !filter.MatchString(row.User) {
			continue
		}
		delta := row.Connections - old[key{row.User, row.ClientHost, row.ServerHost, row.Schema}]
		deltaText := "0"
		if _, exists := old[key{row.User, row.ClientHost, row.ServerHost, row.Schema}]; exists && delta != 0 {
			deltaText = fmt.Sprintf("%+d", delta)
		}
		line := fmt.Sprintf("%-15s %-20s %-25s %-15s %6d %7s",
			truncate(row.User, 15), truncate(row.ClientHost, 20),
			truncate(row.ServerHost, 25), truncate(row.Schema, 15),
			row.Connections, deltaText)
		color := green
		if threshold > 0 && row.Connections >= threshold {
			color = red
		}
		clean, colored = append(clean, line), append(colored, color+line+reset)
		count++
	}
	return render(clean, colored, count), nil
}

func FormatQueries(rows []model.QueryRow, userFilter string, terminalWidth int) (model.RenderedView, error) {
	filter, err := CompileUserFilter(userFilter)
	if err != nil {
		return model.RenderedView{}, err
	}
	queryWidth := max(20, terminalWidth-84)
	header := fmt.Sprintf("%-8s %-5s %-12s %-16s %-20s %8s %-*s",
		"PSID", "HG", "USER", "SOURCE", "BACKEND", "TIME", queryWidth, "ACTIVE QUERY")
	clean, colored := []string{header}, []string{bold + header + reset}
	count := 0
	for _, row := range rows {
		if !filter.MatchString(row.User) {
			continue
		}
		line := fmt.Sprintf("%-8s %-5s %-12s %-16s %-20s %8d %-*s",
			truncate(row.SessionID, 8), truncate(row.Hostgroup, 5), truncate(row.User, 12),
			truncate(row.ClientHost, 16), truncate(row.ServerHost, 20), row.TimeMS,
			queryWidth, truncate(Sanitize(row.Query), queryWidth))
		color := cyan
		if row.TimeMS > 1000 {
			color = red
		} else if row.TimeMS > 500 {
			color = yellow
		}
		clean, colored = append(clean, line), append(colored, color+line+reset)
		count++
	}
	return render(clean, colored, count), nil
}

func FormatDigests(rows []model.DigestRow, terminalWidth int) model.RenderedView {
	queryWidth := max(50, terminalWidth-60)
	header := fmt.Sprintf("%-14s %6s %10s %10s %10s %-*s",
		"DIGEST", "COUNT", "SUM_TIME", "MIN_TIME", "MAX_TIME", queryWidth, "QUERY TEXT")
	clean, colored := []string{header}, []string{bold + header + reset}
	for _, row := range rows {
		line := fmt.Sprintf("%-14s %6d %10d %10d %10d %-*s",
			truncate(row.Digest, 14), row.Count, row.SumTime, row.MinTime, row.MaxTime,
			queryWidth, truncate(Sanitize(row.Query), queryWidth))
		clean, colored = append(clean, line), append(colored, cyan+line+reset)
	}
	return render(clean, colored, len(rows))
}

func FormatBackend(rows model.BackendRows) model.RenderedView {
	header := fmt.Sprintf("%-10s %-30s %-12s %7s %7s %10s %8s",
		"HOSTGROUP", "BACKEND HOST", "STATUS", "USED", "FREE", "OK", "ERR")
	clean, colored := []string{header}, []string{bold + header + reset}
	for _, row := range rows.Pool {
		line := fmt.Sprintf("%-10s %-30s %-12s %7d %7d %10d %8d",
			truncate(row.Hostgroup, 10), truncate(row.ServerHost, 30), truncate(row.Status, 12),
			row.ConnUsed, row.ConnFree, row.ConnOK, row.ConnErr)
		color := red
		if row.Status == "ONLINE" && row.ConnErr == 0 {
			color = green
		}
		clean, colored = append(clean, line), append(colored, color+line+reset)
	}
	pingHeader := fmt.Sprintf("%-30s %-20s %12s %s", "PING HOST", "LAST PING", "SUCCESS_US", "ERROR")
	clean, colored = append(clean, pingHeader), append(colored, bold+pingHeader+reset)
	for _, row := range rows.Ping {
		success := ""
		if row.SuccessUS != nil {
			success = strconv.Itoa(*row.SuccessUS)
		}
		line := fmt.Sprintf("%-30s %-20s %12s %s",
			truncate(row.Hostname, 30), truncate(row.LastPing, 20), success, Sanitize(row.Error))
		color := green
		if row.Error != "" {
			color = red
		}
		clean, colored = append(clean, line), append(colored, color+line+reset)
	}
	return render(clean, colored, len(rows.Pool)+len(rows.Ping))
}
