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
	orange = "\x1b[1;38;5;208m"
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
	)
	value = replacer.Replace(value)
	value = strings.Map(func(character rune) rune {
		if character < 32 || (character >= 127 && character <= 159) {
			return ' '
		}
		return character
	}, value)
	return strings.Join(strings.Fields(value), " ")
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
		if fields[2] != "" && !strings.EqualFold(fields[2], "NULL") {
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
	header := fmt.Sprintf("%-20s | %-15s | %-28s | %-20s | %-10s | %-10s",
		"USER", "SOURCE (Cli)", "BACKEND (Srv)", "SCHEMA", "CONN", "DELTA")
	clean, colored := []string{header}, []string{bold + header + reset}
	count := 0
	totalConnections, totalDelta := 0, 0
	for _, row := range rows {
		if !filter.MatchString(Sanitize(row.User)) {
			continue
		}
		rowKey := key{row.User, row.ClientHost, row.ServerHost, row.Schema}
		previousValue, exists := old[rowKey]
		delta := row.Connections - previousValue
		deltaText := "0"
		if !exists {
			delta = 0
		} else if delta != 0 {
			deltaText = fmt.Sprintf("%+d", delta)
		}
		totalConnections += row.Connections
		totalDelta += delta
		line := fmt.Sprintf("%-20s | %-15s | %-28s | %-20s | %-10d | %-10s",
			truncate(Sanitize(row.User), 20), truncate(Sanitize(row.ClientHost), 15),
			truncate(Sanitize(row.ServerHost), 28), truncate(Sanitize(row.Schema), 20),
			row.Connections, deltaText)
		color := green
		if threshold > 0 && row.Connections >= threshold {
			color = red
		}
		clean, colored = append(clean, line), append(colored, color+line+reset)
		count++
	}
	if totalConnections > 0 {
		deltaText := "0"
		if totalDelta != 0 {
			deltaText = fmt.Sprintf("%+d", totalDelta)
		}
		line := fmt.Sprintf("%-20s | %-15s | %-28s | %-20s | %-10d | %-10s",
			"GLOBAL TOTALS", "", "", "", totalConnections, deltaText)
		clean, colored = append(clean, line), append(colored, bold+cyan+line+reset)
	}
	return render(clean, colored, count), nil
}

func FormatQueries(rows []model.QueryRow, userFilter string, terminalWidth int) (model.RenderedView, error) {
	filter, err := CompileUserFilter(userFilter)
	if err != nil {
		return model.RenderedView{}, err
	}
	queryWidth := max(20, terminalWidth-97)
	header := fmt.Sprintf("%-8s | %-4s | %-15s | %-15s | %-28s | %-9s | %-*s",
		"PSID", "HG", "USER", "SOURCE", "BACKEND", "TIME", queryWidth, "ACTIVE QUERY")
	clean, colored := []string{header}, []string{bold + header + reset}
	count := 0
	for _, row := range rows {
		if !filter.MatchString(Sanitize(row.User)) {
			continue
		}
		line := fmt.Sprintf("%-8s | %-4s | %-15s | %-15s | %-28s | %-9s | %-*s",
			truncate(Sanitize(row.SessionID), 8), truncate(Sanitize(row.Hostgroup), 4),
			truncate(Sanitize(row.User), 15), truncate(Sanitize(row.ClientHost), 15),
			truncate(Sanitize(row.ServerHost), 28), fmt.Sprintf("%dms", row.TimeMS),
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
	queryWidth := max(20, terminalWidth-73)
	header := fmt.Sprintf("%-18s | %-10s | %-10s | %-10s | %-10s | %-*s",
		"DIGEST", "COUNT", "SUM_TIME", "MIN_TIME", "MAX_TIME", queryWidth, "QUERY TEXT")
	clean, colored := []string{header}, []string{bold + header + reset}
	for _, row := range rows {
		line := fmt.Sprintf("%-18s | %-10d | %-10d | %-10d | %-10d | %-*s",
			truncate(Sanitize(row.Digest), 18), row.Count, row.SumTime, row.MinTime, row.MaxTime,
			queryWidth, truncate(Sanitize(row.Query), queryWidth))
		clean, colored = append(clean, line), append(colored, cyan+line+reset)
	}
	return render(clean, colored, len(rows))
}

func backendStatusColor(status string) string {
	switch strings.ToUpper(strings.TrimSpace(status)) {
	case "ONLINE":
		return green
	case "SHUNNED":
		return yellow
	case "OFFLINE_SOFT":
		return orange
	case "OFFLINE_HARD":
		return red
	default:
		return red
	}
}

func FormatBackend(rows model.BackendRows) model.RenderedView {
	header := fmt.Sprintf("%-10s | %-35s | %-15s | %-11s | %-11s | %-11s | %-11s",
		"HOSTGROUP", "BACKEND HOST", "STATUS", "CONN USED", "CONN FREE", "CONN OK", "CONN ERR")
	clean, colored := []string{header}, []string{bold + header + reset}
	for _, row := range rows.Pool {
		line := fmt.Sprintf("%-10s | %-35s | %-15s | %-11d | %-11d | %-11d | %-11d",
			truncate(Sanitize(row.Hostgroup), 10), truncate(Sanitize(row.ServerHost), 35),
			truncate(Sanitize(row.Status), 15),
			row.ConnUsed, row.ConnFree, row.ConnOK, row.ConnErr)
		color := backendStatusColor(row.Status)
		clean, colored = append(clean, line), append(colored, color+line+reset)
	}
	pingHeader := fmt.Sprintf("%-35s | %-25s | %-15s | %s",
		"HOSTNAME", "LAST PING DATETIME", "SUCCESS (us)", "PING ERROR")
	clean, colored = append(clean, pingHeader), append(colored, bold+pingHeader+reset)
	for _, row := range rows.Ping {
		success := ""
		if row.SuccessUS != nil {
			success = strconv.Itoa(*row.SuccessUS)
		}
		line := fmt.Sprintf("%-35s | %-25s | %-15s | %s",
			truncate(Sanitize(row.Hostname), 35), truncate(Sanitize(row.LastPing), 25),
			success, Sanitize(row.Error))
		normalizedError := strings.ToUpper(strings.TrimSpace(row.Error))
		color := green
		if normalizedError != "" && normalizedError != "NULL" {
			color = red
		}
		clean, colored = append(clean, line), append(colored, color+line+reset)
	}
	return render(clean, colored, len(rows.Pool)+len(rows.Ping))
}
