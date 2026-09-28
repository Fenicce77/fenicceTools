# InnoDB Tools

## Supported tools

### `innodb_status_analyzer.sh`

Analyzes timestamped `SHOW ENGINE INNODB STATUS` samples and reports active
deadlocks and persistent locks. Sample filenames must use the canonical
`YYYYMMDD_HH.sample` format.

```bash
./innodb_status_analyzer.sh --dir /var/log/mysql/innodb --mode all --report-mode both
./innodb_status_analyzer.sh --file 20260928_13.sample --mode deadlocks --no-color
```

Use `--help` for the complete CLI contract. The analyzer supports selection by
directory, explicit files, or pattern; time, table, and user filters; screen,
file, or combined reports; and CSV output with `--output-dir`.

Historical analyzer implementations are preserved byte-for-byte under
`innodb_analyzer/legacy/`. They are archival material, not supported commands.

### `innodb_engine_status_sampler/innodb_engine_status.sampler.sh`

Captures `SHOW ENGINE INNODB STATUS` samples using the canonical instance-name
configuration contract. It supports scheduled file capture and local display
mode; run `--help` for usage and examples.

## Historical and maintenance scripts

The remaining root-level scripts are retained for compatibility and are pending
the same standardization review. Do not use them as replacements for the two
supported tools above without reviewing their individual operational contracts.
