# shellcheck shell=bash
#
# metrics.sh - Phase 5: optional Prometheus textfile-collector metrics.
#
# Enabled when METRICS_DIR is set. Files are written atomically (temp file in
# the same directory + mv) so the collector never reads a partial file:
#   pbm_backup_run_<command>.prom  outcome of the last run of each command
#   pbm_backup_state.prom          backup / PITR / agent state seen by PBM
# Each metric lives in exactly one file (node_exporter rejects duplicates).
#
# Typical directories:
#   node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
#   PMM2: /usr/local/percona/pmm2/collectors/textfile-collector/low-resolution
#   PMM3: /usr/local/percona/pmm/collectors/textfile-collector/low-resolution
#
# Requires: common.sh, mongo.sh, pbm.sh, jq.

# metrics_enabled - true when METRICS_DIR is set.
metrics_enabled() {
    [[ -n ${METRICS_DIR:-} ]]
}

# metrics_labels - common labels: replica set and this node.
metrics_labels() {
    local rs
    rs=$(uri_param "${PBM_MONGODB_URI:-}" replicaSet)
    printf 'rs="%s",node="%s"' "${rs:-unknown}" "$(hostname -s 2>/dev/null || hostname)"
}

# metrics_write FILE CONTENT - atomic write into METRICS_DIR. Never fails the
# caller: problems are logged as warnings.
metrics_write() {
    local file=$1 content=$2 tmp
    if ! mkdir -p "$METRICS_DIR" 2>/dev/null; then
        log WARN "${LOG_LABEL:-[PBM-BACKUP]}[METRICS]" "Cannot create METRICS_DIR ${METRICS_DIR}"
        return 0
    fi
    tmp="${METRICS_DIR}/.${file}.$$"
    if printf '%s\n' "$content" >"$tmp" 2>/dev/null && chmod 0644 "$tmp" 2>/dev/null && mv -f "$tmp" "${METRICS_DIR}/${file}"; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    log WARN "${LOG_LABEL:-[PBM-BACKUP]}[METRICS]" "Cannot write ${METRICS_DIR}/${file}"
}

# metrics_run COMMAND OUTCOME(ok|skipped|failed) STARTED_EPOCH
metrics_run() {
    metrics_enabled || return 0
    local cmd=$1 outcome=$2 started=$3 now l
    now=$(now_epoch)
    l="$(metrics_labels),command=\"${cmd}\",scheme=\"${STRATEGY:-unknown}\""
    metrics_write "pbm_backup_run_${cmd}.prom" "# HELP pbm_backup_run_last_timestamp_seconds When the last run of this command finished.
# TYPE pbm_backup_run_last_timestamp_seconds gauge
pbm_backup_run_last_timestamp_seconds{${l}} ${now}
# HELP pbm_backup_run_duration_seconds Duration of the last run of this command.
# TYPE pbm_backup_run_duration_seconds gauge
pbm_backup_run_duration_seconds{${l}} $(( now - started ))
# HELP pbm_backup_run_success 1 if the last run succeeded or was skipped on purpose, 0 if it failed.
# TYPE pbm_backup_run_success gauge
pbm_backup_run_success{${l}} $([[ $outcome == failed ]] && echo 0 || echo 1)
# HELP pbm_backup_run_skipped 1 if the last run did nothing on purpose (another node's turn, already done).
# TYPE pbm_backup_run_skipped gauge
pbm_backup_run_skipped{${l}} $([[ $outcome == skipped ]] && echo 1 || echo 0)"
}

# metrics_state STATUS_JSON SNAPSHOTS_JSON [PITR_COVERAGE_JSON] [ELECTION_JSON]
#   Backup state as PBM reports it. Every node writes its own copy; alert on
#   the max/min across nodes of the same replica set.
metrics_state() {
    metrics_enabled || return 0
    local status=$1 snaps=$2 cov=${3:-} election=${4:-} l body
    l=$(metrics_labels)
    body=$(jq -rn --argjson st "$status" --argjson sn "$snaps" \
        --argjson cov "${cov:-null}" --argjson el "${election:-null}" --arg l "$l" '
        def kind: if .type == "logical" then "logical"
                  elif (.src // "") == "" then "base"
                  else "incremental" end;
        def done: [ $sn[] | select(.status == "done") ];
        def last(k): [ done[] | select(kind == k) ] | sort_by(.name) | last;
        [
          "# HELP pbm_backup_last_restore_timestamp_seconds Consistency point (restoreTo) of the newest successful backup of each kind.",
          "# TYPE pbm_backup_last_restore_timestamp_seconds gauge",
          ( ["base", "incremental", "logical"][] as $k | last($k) | select(. != null)
            | "pbm_backup_last_restore_timestamp_seconds{\($l),kind=\"\($k)\"} \(.restoreTo // 0)" ),
          "# HELP pbm_backup_last_size_bytes Size of the newest successful backup of each kind.",
          "# TYPE pbm_backup_last_size_bytes gauge",
          ( ["base", "incremental", "logical"][] as $k | last($k) | select(. != null)
            | "pbm_backup_last_size_bytes{\($l),kind=\"\($k)\"} \(.size // 0)" ),
          "# HELP pbm_backup_snapshots Number of backups by status.",
          "# TYPE pbm_backup_snapshots gauge",
          ( $sn | group_by(.status)[] | "pbm_backup_snapshots{\($l),status=\"\(.[0].status)\"} \(length)" ),
          "# HELP pbm_pitr_enabled 1 if PBM PITR (oplog slicing) is enabled.",
          "# TYPE pbm_pitr_enabled gauge",
          "pbm_pitr_enabled{\($l)} \(if $st.pitr.conf == true then 1 else 0 end)",
          "# HELP pbm_pitr_running 1 if a node is currently slicing the oplog.",
          "# TYPE pbm_pitr_running gauge",
          "pbm_pitr_running{\($l)} \(if $st.pitr.run == true then 1 else 0 end)",
          ( if $cov != null then
              "# HELP pbm_pitr_coverage_ok 1 if saved oplog covers the last logical full up to now with no gap and acceptable lag.",
              "# TYPE pbm_pitr_coverage_ok gauge",
              "pbm_pitr_coverage_ok{\($l)} \(if $cov.ok then 1 else 0 end)",
              "# HELP pbm_pitr_gaps Number of gaps in the saved oplog after the last logical full.",
              "# TYPE pbm_pitr_gaps gauge",
              "pbm_pitr_gaps{\($l)} \($cov.gaps | length)",
              ( if $cov.lag != null then
                  "# HELP pbm_pitr_lag_seconds Seconds between now and the newest saved oplog.",
                  "# TYPE pbm_pitr_lag_seconds gauge",
                  "pbm_pitr_lag_seconds{\($l)} \($cov.lag)"
                else empty end )
            else empty end ),
          "# HELP pbm_agent_ok 1 if the pbm-agent of the member is ok.",
          "# TYPE pbm_agent_ok gauge",
          ( $st.cluster[]?.nodes[]? | "pbm_agent_ok{\($l),member=\"\(.host)\",role=\"\(.role)\"} \(if .ok then 1 else 0 end)" ),
          ( if $el != null then
              "# HELP pbm_backup_member_eligible 1 if the member can take backups now (healthy secondary).",
              "# TYPE pbm_backup_member_eligible gauge",
              ( $el[] | "pbm_backup_member_eligible{\($l),member=\"\(.host)\"} \(if .eligible then 1 else 0 end)" ),
              "# HELP pbm_oplog_window_seconds Oplog window of the member (newest minus oldest entry).",
              "# TYPE pbm_oplog_window_seconds gauge",
              ( $el[] | select(.probe.oplog_window_sec != null)
                | "pbm_oplog_window_seconds{\($l),member=\"\(.host)\"} \(.probe.oplog_window_sec)" ),
              "# HELP pbm_replication_lag_seconds Replication lag of the member.",
              "# TYPE pbm_replication_lag_seconds gauge",
              ( $el[] | select(.probe.lag != null)
                | "pbm_replication_lag_seconds{\($l),member=\"\(.host)\"} \(.probe.lag)" )
            else empty end ),
          "# HELP pbm_backup_state_timestamp_seconds When this state file was written.",
          "# TYPE pbm_backup_state_timestamp_seconds gauge",
          "pbm_backup_state_timestamp_seconds{\($l)} \(now | floor)"
        ] | .[]') || { log WARN "${LOG_LABEL:-[PBM-BACKUP]}[METRICS]" "Cannot build state metrics"; return 0; }
    metrics_write pbm_backup_state.prom "$body"
}
