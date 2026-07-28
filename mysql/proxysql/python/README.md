# ProxySQL Ultimate Monitor — Python

An install-free Python 3.9+ port of the DBA Edition monitor for macOS and
Linux. It queries ProxySQL through the system `mysql` client and preserves
credentials in MySQL login paths.

## Requirements

- Python 3.9 or newer.
- MySQL command-line client (`mysql` and `mysql_config_editor`).
- A login path that connects to the ProxySQL admin interface.

No Python packages are required.
For a keg-only client, set `MYSQL_BIN` to its absolute path, for example
`/opt/homebrew/opt/mysql-client/bin/mysql`.

## Usage

```text
./proxysql_connections_monitor.py --login-path=NAME [OPTIONS]

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

The process keeps one persistent `mysql --login-path` child. A request timeout
or broken child causes one reconnect and one retry. Reader queues and stderr
history are bounded to prevent memory growth. Normal mode queries only the
visible view. Batch escaping remains enabled so literal query newlines cannot
break framed row boundaries; `--force` is intentionally disabled so SQL errors
terminate the frame and cannot be reported as empty successful samples. The
formatter normalizes escaped controls and neutralizes terminal control bytes.
Output logging writes fresh nonempty samples directly from clean logical data
and never post-processes ANSI output.

## Examples

```bash
./proxysql_connections_monitor.py --login-path=proxysql_admin
./proxysql_connections_monitor.py --login-path=proxysql_admin -u 'app,report' -t 20
./proxysql_connections_monitor.py --login-path=proxysql_admin -o /tmp/proxysql.log
su - rmateos -c './proxysql_connections_monitor.py --login-path=proxysql_admin -r 0.5'
```

## Tests

```bash
python3 -m unittest discover -s tests -v
python3 -m compileall -q .
```

The live smoke mode executes `SELECT` statements only. It uses one persistent
client per node and checks CONN, QUERY, DIGEST, and BACKEND in order:

```bash
./proxysql_connections_monitor.py \
  --smoke-test \
  --login-path=devel-proxysql01-node01 \
  --login-path=devel-proxysql01-node02 \
  --login-path=devel-proxysql01-node03
```
