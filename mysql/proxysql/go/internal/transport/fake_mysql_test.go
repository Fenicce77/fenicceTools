package transport

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func TestMain(m *testing.M) {
	if os.Getenv("GO_WANT_FAKE_MYSQL") == "1" {
		os.Exit(runFakeMySQL())
	}
	os.Exit(m.Run())
}

func TestFakeMySQLProcess(t *testing.T) {
	if os.Getenv("GO_WANT_FAKE_MYSQL") != "1" {
		t.Skip("helper process only")
	}
	t.Fatal("fake process must run through TestMain")
}

func runFakeMySQL() int {
	state := os.Getenv("FAKE_MYSQL_STATE_DIR")
	if err := os.MkdirAll(state, 0o755); err != nil {
		return 3
	}
	launches, err := os.OpenFile(filepath.Join(state, "launches"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return 3
	}
	_, _ = fmt.Fprintln(launches, os.Getpid())
	_ = launches.Close()

	stderrLines, _ := strconv.Atoi(os.Getenv("FAKE_MYSQL_STDERR_LINES"))
	for index := 0; index < stderrLines; index++ {
		fmt.Fprintf(os.Stderr, "fake stderr %d\n", index)
	}

	responses := map[string]string{
		"TEST_CONNECTIONS":   "app\tclient\tbackend:3306\tappdb\t4",
		"TEST_SECOND_SAMPLE": "app\tclient\tbackend:3306\tappdb\t6",
		"SELECT @@version":   "2.7.3",
		"SELECT @@hostname":  "proxysql-test",
	}
	markerPattern := regexp.MustCompile(`'(__PXMON_(?:BEGIN|END)_\d+__)'`)
	dropEnd := os.Getenv("FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH") == "1"
	dropFile := filepath.Join(state, "drop_done")
	exitToken := os.Getenv("FAKE_MYSQL_EXIT_ON_TOKEN")
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		if exitToken != "" && strings.Contains(line, exitToken) {
			return 2
		}
		if match := markerPattern.FindStringSubmatch(line); match != nil {
			if strings.Contains(match[1], "_END_") && dropEnd {
				if _, err := os.Stat(dropFile); os.IsNotExist(err) {
					_ = os.WriteFile(dropFile, []byte("1"), 0o600)
					continue
				}
			}
			fmt.Println(match[1])
			continue
		}
		for token, response := range responses {
			if strings.Contains(line, token) {
				fmt.Println(response)
				break
			}
		}
	}
	return 0
}
