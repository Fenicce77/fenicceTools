# Tool Modernization Inventory

Last inventory refresh: 2026-10-05. This ledger is the authoritative planning view for user-facing executable tools in this repository. It is based on current `main` through PR #15. It records verified work only; `pending audit` means neither deprecated nor production-approved.

The inventory excludes tests, mocks, fixtures, vendored dependencies, generated migration artifacts and linked worktrees. A wrapper is listed only when it is an operational entry point.

## Status legend

| Status | Meaning |
|---|---|
| `standardized` | Canonical command with documented contract and verified regression coverage. |
| `documented` | Operational contract and validation evidence are documented; live validation may still be explicitly pending. |
| `legacy` | Historical or compatibility implementation; do not invoke for new work. |
| `pending audit` | Active executable not yet reviewed against the repository tool standard. |
| `test helper` | Fixture, fake client, benchmark or test runner; not a user-facing command. |

## Executive dashboard

| Domain | Active commands | Standardized / documented | Pending audit | Legacy | Latest verified update |
|---|---:|---:|---:|---:|---|
| MongoDB / `backupTool` | 2 | 2 | 0 | 3 compatibility wrappers | 2026-10-05 |
| MongoDB / other tools | 14 | 0 | 14 | 0 | Not yet audited |
| MySQL / InnoDB | 3 | 3 | 0 | 10 | 2026-09-29 |
| MySQL / binlogs | 1 | 1 | 0 | 8 | 2026-09-30 |
| MySQL / monitoring | 3 | 3 | 0 | 0 | 2026-08-21 |
| MySQL / sessions | 4 | 4 | 0 | 0 | 2026-08-12 |
| MySQL / transactions | 6 | 6 | 0 | 0 | 2026-08-12 |
| MySQL / analysis | 2 | 2 | 0 | 0 | 2026-08-11 |
| MySQL / estimations | 3 | 3 | 0 | 0 | 2026-08-09 |
| MySQL / ProxySQL | 3 | 3 | 0 | 0 | 2026-08-12 |
| MySQL / other active areas | 23 | 0 | 23 | 7 | Not yet audited |
| Generic, partitioning, root ProxySQL | 8 | 1 | 7 | 0 | 2026-08-24 |
| `sh/` compatibility and operational scripts | 25 | 0 | 25 | 0 | Not yet audited |
| `sh/mysql_populate/` | 12 | 0 | 12 | 0 | Not yet audited |

Counts describe supported entry points grouped by operational domain. The backupTool legacy count covers executable `sysconfig/pbm-*` compatibility wrappers; legacy systemd units are not commands.

## Completed modernization log

| Date | Scope | State | Primary commits / outcome |
|---|---|---|---|
| 2026-10-05 | MongoDB backupTool PBM 2.12 configuration handling | `documented` | `6fe8f31`, PR #15; reads supported PBM configuration values through JSON and records PBM 2.12 source verification. |
| 2026-10-05 | MongoDB backupTool operation, retention, restore and systemd | `documented` | `e7679b3`, `ac413f1`, `5a273fc`, `6c4ff25`, PR #14; logical/physical schemes, chain-safe retention, guarded restore, systemd installation, metrics and PBM 2.12 documentation. |
| 2026-09-30 | MySQL binlog activity reporting | `standardized` | `dde301b`, PR #13; canonical local/remote report, event-level MySQL/MariaDB parsing, ANSI-free CSV and eight archived variants. |
| 2026-09-29 | InnoDB sampler connection template | `standardized` | `0834776`; canonical template, explicit password placeholder, runtime config ignored. |
| 2026-09-29 | InnoDB sample-retention configuration | `standardized` | `72ad6ee`; generic template under `mysql/innodb/conf/`. |
| 2026-09-28 | InnoDB sampler variants | `legacy` | `e1bec2c`; prior versions moved under sampler `legacy/`. |
| 2026-09-28 | InnoDB sample retention | `standardized` | `866d3db`, `357405e`; dry-run default, `--apply`, validated archive workflow. |
| 2026-09-28 | InnoDB analyzer | `standardized` | `f706a5a`, `0a45f02`, `da8f4a9`; canonical unversioned analyzer and regression suite. |
| 2026-09-28 | InnoDB documentation and automation | `documented` | `9036024`, `d900761`, `3d1d6ca`; detailed guide plus systemd and crond templates. |
| 2026-09-28 | pt-osc photographer | `legacy` | `961ff9e`; archived as `innodb_engine_photographer.ptosc.sh`. |
| 2026-09-11 | InnoDB status sampler | `standardized` | `42700c2`; portable capture/display implementation and tests. |
| 2026-08-21 | Buffer pool resize monitor | `standardized` | `26e89c8`, `a64a72e`; safe query set, terminal controls and progress view. |
| 2026-08-12 | Session, transaction, tracker and ProxySQL monitors | `standardized` | CLI, interactive help, colors, safe filters and tests. |
| 2026-08-10–11 | Foreign-key analyzer | `standardized` | Physical/virtual FK topology, colors, reports and test hardening. |
| 2026-08-08 | Porko | `standardized` | `326183b`; transaction batch size is runtime-configurable. |
| 2026-08-24 | Root ProxySQL log parser | `documented` | `b037992`; analysis recorded; full standardization remains pending. |

## MongoDB backupTool

| Path | Status | Updated | Notes |
|---|---|---:|---|
| `mongodb/backupTool/bin/pbm-backup` | `documented` | 2026-10-05 | Canonical PBM 2.x runner for `full`, `incr`, `cleanup`, `restore`, `check` and `metrics`; supports logical and physical schemes. |
| `mongodb/backupTool/install.sh` | `documented` | 2026-10-05 | Systemd installer with `--dry-run`, enablement and legacy-wrapper migration controls. |
| `mongodb/backupTool/tests/smoke.sh` | `test helper` | 2026-10-05 | Mocked `pbm`/`mongosh` scenario tests with PBM 2.12.0 JSON fixtures; no live cluster required. |
| `mongodb/backupTool/systemd/{services,timers}/pbm-backup-*` | `documented` | 2026-10-05 | Current full, incremental, cleanup and Prometheus-metrics service/timer families. |
| `mongodb/backupTool/systemd/legacy/` | `legacy` | 2026-10-05 | Retained historical physical/deletion unit files. |
| `mongodb/backupTool/sysconfig/pbm-deletion`, `pbm-physical-full-base`, `pbm-physical-incremental` | `legacy` | 2026-10-05 | Compatibility wrappers; use `pbm-backup` for new operations. |

The backupTool README records remaining live-cluster validation gaps: Community PITR execution, `buildInfo.psmdbVersion`, MongoDB 8.0 `globalLock.currentQueue`, and dynamic PBM `backup.priority`. Do not mark it `standardized` until those boundaries have production evidence.

## Canonical and archived MySQL commands

| Path | Status | Updated | Notes |
|---|---|---:|---|
| `mysql/binlogs/binlog_activity_report.sh` | `standardized` | 2026-09-30 | Canonical local/remote MySQL/MariaDB report; 182 regression assertions. |
| `mysql/binlogs/legacy/*.sh` | `legacy` | 2026-09-30 | Eight historical binlog variants retained byte-for-byte. |
| `mysql/innodb/innodb_engine_status_sampler/innodb_engine_status.sampler.sh` | `standardized` | 2026-09-29 | Canonical capture and display command; sampler suite has 34 assertions. |
| `mysql/innodb/innodb_status_analyzer.sh` | `standardized` | 2026-09-28 | Canonical read-only analysis command. |
| `mysql/innodb/compress.sample.files.sh` | `standardized` | 2026-09-28 | Safe retention with dry-run default. |
| `mysql/innodb/innodb_engine_status_sampler/conf/mysql.instance.conn.template.cnf` | `standardized` | 2026-09-29 | Connection template; runtime `.conf/*.cnf` is ignored. |
| `mysql/innodb/conf/compress.sample.files.template.cnf` | `standardized` | 2026-09-29 | Retention template. |
| `mysql/innodb/**/legacy/*` | `legacy` | 2026-09-28 | Historical analyzer and sampler versions; retained byte-for-byte. |
| `mysql/innodb/legacy/innodb_engine_photographer.ptosc.sh` | `legacy` | 2026-09-28 | Former pt-osc gated sampler. |

## Pending audit backlog

Each row below is an active inventory group. Audit listed files together when they share an operational domain, then split them into separate work items if their contracts differ.

| Priority | Scope and executable inventory | State | Next audit objective |
|---:|---|---|---|
| 1 | `mongodb/betika_mongodb_normalized/`, `mongodb/mongodb_bootstrap_startup/`, `mongodb/monitoringTools/sh/`, `mongodb/sh/mongoconn.gcss.*.sh`, `mongodb/plgm-darwin-arm64` | `pending audit` | Classify normalizers, bootstrap scripts, monitoring utilities, connection helpers and the opaque binary before operational recommendation. |
| 1 | `mysql/Replication/`: `MySQLSlaveCheck.sh`, `MySQLSlaveCheck2.sh`, `Sync_replica_1032.sh`, `Sync_replica_1032_nogtid.sh`, `Sync_replica_rds_1032_1062.sh` | `pending audit` | Classify replication checks versus corrective scripts; make corrective actions explicit and guarded. |
| 1 | `mysql/mysqldump/`: `mysql_logical_dump_dbs.sh`, `mysql_logical_dump_dbs_remote.sh`, `mysql_nodata_dump_dbs.sh`, `mysql_nodata2_dump_dbs.sh`; plus `mysql/mysql_logical_restore_dbs.sh` | `pending audit` | Establish backup/restore safety contract, credentials model, retention and non-destructive defaults. |
| 2 | `mysql/execute_sql_controled.ecomm-fraud.sh`, `mysql/execute_sql_controled.v1.sh`, `mysql/execute_sql_controled_new.sh` | `pending audit` | Select canonical controlled-SQL executor and require explicit apply/target validation. |
| 2 | `mysql/general_log/`: `gcp_general_log_monitor.sh`; `mysql/general_log_dump.sh` | `pending audit` | Review cloud privilege assumptions, data handling and output retention. |
| 2 | `mysql/PXC/`: `gcacheSize_estimation_calc.sh`, `writesets_still_waiting.sh` | `pending audit` | Validate Galera/PXC compatibility and query cost. |
| 2 | `mysql/check_temporary_files.sh`, `mysql/Innodb_buffer_pool_status.check.sh`, `mysql/innodb_engine_status.sampler.sh`, `mysql/innodb_engine_status_parser.sh` | `pending audit` | Determine whether these root-level commands duplicate canonical monitored tools. |
| 2 | `mysql/encrypt_pass.sh`, `mysql/encrypt_pass2.sh`, `mysql/mysql_encrypt_pass.sh`, `mysql/mysql_encrypt_pass_loop.sh` | `pending audit` | Audit crypto design and secret handling before any operational recommendation. |
| 3 | `mysql/olderscripts/`: `MySQL.qps.sh`, `MySQLLockedTransactions.sh`, `MySQLLongRunningTrans1Sec.InfSchema.sh`, `MySQLOpenedTransactions.sh`, `MySQLReportLatestQry4Trans1Sec.sh`, `ReportHighQPSProcesslist.sh`, `search.sh` | `pending audit` | Decide archive versus modernization; do not execute in production until classified. |
| 3 | `generic/`: `check_opened_sessions.sh`, `generate_queries.sh`, `search.sh`, `user_mod.sh` | `pending audit` | Identify duplicated MySQL/session behavior and global utility contracts. |
| 3 | `partitioning/`: `osc_partition_generator.sh`, `populatepartTable.sh`, `v2/osc_partition_generator.sh` | `pending audit` | Select canonical partitioning generator; classify destructive schema operations. |
| 3 | Root `proxysql/proxysql_log_parser.sh` | `pending audit` | Complete the standardization outlined by the 2026-08-24 analysis. |
| 3 | `rdsproxytest/sh/` | `pending audit` | Inventory separately before assigning a production support status. |
| 4 | `sh/`: `MySQLSlaveCheck.sh`, `check_opened_sessions.madcol.sh`, `encrypt_pass.sh`, `innodb/innodb_engine_status.sampler.sh`, `kk.sh`, `mon_open_files_lsof.sh`, `mon_open_files_nolsof.sh`, `multi_filetouch.sh` | `pending audit` | Map duplicates to canonical MySQL tools; archive only after reference analysis. |
| 4 | `sh/binlogs/`: `summarize_binlogs.sh`, `summarize_binlogs_notbinary.sh`, `summarize_binlogs_notbinary.top7.sh`, `summarize_binlogs_notbinary.zipped.sh` | `pending audit` | Consolidate with the canonical `mysql/binlogs/` report and decide archive/replacement mappings. |
| 4 | `sh/compress/`: `compress_sample_files.sh`, `compress_sample_files_month.sh` | `pending audit` | Consolidate with canonical InnoDB retention. |
| 4 | `sh/mysql_populate/`: `generateInsertFiles.sh`, `multi_populate_mysqlserver*.sh`, `populate*.sh` | `pending audit` | Classify data generation versus target mutation; define safe target guards. |
| 4 | `sh/pt-tools/ptosc/ptosc_progress.sh` | `pending audit` | Review after the broader pt-osc workflow is selected. |

## Already standardized outside InnoDB

| Domain | Canonical command / implementation | Last verified update |
|---|---|---:|
| Binlog activity | `mysql/binlogs/binlog_activity_report.sh` | 2026-09-30 |
| Foreign-key analysis | `mysql/analysis/fk_analyzer.sh` | 2026-08-11 |
| Prefix, cardinality and storage estimation | `mysql/estimations/analyze_prefix_index.sh`, `check_cardinality.sh`, `estimate_storage.sh` | 2026-08-09 |
| Transaction monitoring | `mysql/trx/mysql_trx_monitor.sh` | 2026-08-12 |
| Open session monitoring | `mysql/sessions/check_opened_sessions_interactive.sh` | 2026-08-12 |
| Buffer pool monitoring | `mysql/monitoring/bp_tracker.sh`, `mysql/Innodb_buffer_pool_status.check.sh` | 2026-08-21 |
| ProxySQL connection monitoring | `mysql/proxysql/proxysql_connections_monitor.sh` | 2026-08-12 |

## Inventory refresh commands

Run these commands from the repository root before changing any status:

```bash
# Active executable inventory, excluding test, archive and dependency artifacts.
find . -type f -perm -u+x \
  -not -path './.git/*' \
  -not -path './.worktrees/*' \
  -not -path '*/tests/*' \
  -not -path '*/legacy/*' \
  -not -path '*/node_modules/*' \
  | sort

# Historical modernization evidence, including merged work.
git log main --date=short --pretty=format:'%h|%ad|%s' \
  --since='2026-08-01'

# Verify that the inventory branch contains only documentation changes.
git diff --name-status origin/main...HEAD

# Repository and worktree safety check.
git status --short --branch
git worktree list
```

When a tool is audited, update its row with the date, canonical path, commit, test command and disposition. Do not delete a `pending audit` entry merely because a similarly named tool becomes canonical; record the archival or replacement path explicitly.
