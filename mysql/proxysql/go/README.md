# ProxySQL Ultimate Monitor — Go

An idiomatic Go 1.22+ port of the DBA Edition monitor for macOS and Linux.
Credentials remain exclusively in MySQL login paths; the monitor never accepts
password or DSN arguments.

## Requirements and build

- Go 1.22 or newer.
- MySQL command-line client (`mysql` and `mysql_config_editor`).
- A login path that connects to the ProxySQL admin interface.

```bash
go build -o proxysql-monitor ./cmd/proxysql-monitor
./proxysql-monitor --help
```

The only Go dependency is `golang.org/x/term` v0.20.0. For a keg-only MySQL
client, set `MYSQL_BIN=/opt/homebrew/opt/mysql-client/bin/mysql`. The optional
`MYSQL_CONFIG_EDITOR_BIN` override controls host-label resolution.

## Options and keys

```text
proxysql-monitor --login-path=NAME [OPTIONS]

--login-path=NAME           MySQL login path; repeat only in smoke mode.
-r, --refresh-time=SECONDS Refresh interval, including fractions (default: 5).
-u, --user-filter=REGEX    User regex; commas are alternatives.
-t, --threshold=COUNT      Connection alert threshold (default: 0).
-o, --output-file=FILE     Append clean, ANSI-free samples with data.
--query-timeout=SECONDS     SQL request timeout (default: 5).
--smoke-test               Query all four views sequentially and exit.
-h, --help                 Show help and examples.
```

Interactive keys: `v` changes view, `r` changes refresh time, `s` changes
CONN sort, `p` pauses/resumes, `u` changes the user filter, `t` changes the
connection threshold, and `q` exits.

The process keeps one persistent MySQL client per node. A failed frame causes
one reconnect and one retry. Stdout and stderr buffers are bounded, and owned
children are explicitly terminated and reaped. Batch escaping remains enabled
so literal query controls cannot corrupt row framing. `--force` is intentionally
disabled so SQL errors terminate the frame instead of appearing as empty
successful samples. Normal mode queries only the visible view. Logging writes
fresh nonempty samples from clean logical data.

## Examples

```bash
./proxysql-monitor --login-path=proxysql_admin
./proxysql-monitor --login-path=proxysql_admin -u 'app,report' -t 20
./proxysql-monitor --login-path=proxysql_admin -o /tmp/proxysql.log
su - rmateos -c './proxysql-monitor --login-path=proxysql_admin -r 0.5'
```

## Verification

```bash
go test ./...
go test -race ./...
go vet ./...
```

Smoke mode executes `SELECT` statements only, using one client per node and
checking CONN, QUERY, DIGEST, and BACKEND in order:

```bash
go run ./cmd/proxysql-monitor \
  --smoke-test \
  --login-path=devel-proxysql01-node01 \
  --login-path=devel-proxysql01-node02 \
  --login-path=devel-proxysql01-node03
```
