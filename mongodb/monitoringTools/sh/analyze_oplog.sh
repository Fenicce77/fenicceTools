#!/bin/bash

function show_help() {
    echo -e "\n\033[96m\033[1m=== MONGODB OPLOG ANALYZER ===\033[0m\n"
    echo -e "\033[1mDESCRIPTION:\033[0m"
    echo -e "  Analyzes the MongoDB oplog to identify which operations and namespaces"
    echo -e "  are consuming the most space, highlighting trends, time ranges, and TTL deletes.\n"
    echo -e "\033[1mUSAGE:\033[0m"
    echo -e "  $0 <config_file> [options]\n"
    echo -e "\033[1mARGUMENTS:\033[0m"
    echo -e "  \033[93m<config_file>\033[0m         Path to the MongoDB configuration file.\n"
    echo -e "\033[1mOPTIONS:\033[0m"
    echo -e "  \033[92m--include-pbm\033[0m         Include Percona Backup for MongoDB (admin.pbm*) collections."
    echo -e "  \033[92m--exclude-internal\033[0m    Exclude native MongoDB DBs/collections (config, admin, local, system)."
    echo -e "  \033[92m--group <hour|day>\033[0m    Force grouping by 'hour' or 'day'. Adapts dynamically if omitted.\n"
    echo -e "\033[1mEXAMPLES:\033[0m"
    echo -e "  $0 mongo_config.conf"
    echo -e "  $0 mongo_config.conf --exclude-internal"
    echo -e "  $0 mongo_config.conf --group day\n"
    exit 0
}

if [ "$#" -eq 0 ]; then
    show_help
fi

CONFIG_FILE=""
INCLUDE_PBM="false"
EXCLUDE_INTERNAL="false"
GROUP_BY=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --include-pbm) INCLUDE_PBM="true"; shift ;;
        --exclude-internal) EXCLUDE_INTERNAL="true"; shift ;;
        --group) GROUP_BY="$2"; shift 2 ;;
        -h|--help) show_help ;;
        *) CONFIG_FILE="$1"; shift ;;
    esac
done

if [ -z "$CONFIG_FILE" ]; then
    echo -e "\n\033[91mError: You must provide a configuration file.\033[0m"
    show_help
fi

if [[ -n "$GROUP_BY" && "$GROUP_BY" != "hour" && "$GROUP_BY" != "day" ]]; then
    echo -e "\033[91mError: --group must be either 'hour' or 'day'.\033[0m"
    exit 1
fi

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "\033[91mError: Configuration file $CONFIG_FILE not found.\033[0m"
    exit 1
fi

echo -e "\033[96mConnecting to $MONGOHOST and analyzing data...\033[0m"

export NO_UPDATE_NOTIFIER=true
export DISABLE_UPDATE_NOTIFIER=true

JS_FILE=$(mktemp /tmp/analyze_oplog_XXXXXX.js)

cat << EOF > "$JS_FILE"
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const CYAN = "\x1b[36m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";
const MAGENTA = "\x1b[35m"; 

const includePbm = ${INCLUDE_PBM};
const excludeInternal = ${EXCLUDE_INTERNAL};
const forceGroup = "${GROUP_BY}"; 
const oplog = db.getSiblingDB('local').oplog.rs;

let matchStage = { op: { \$in: ["i", "u", "d"] } };
let nsFilters = [];

if (!includePbm) nsFilters.push(/^admin\.pbm/);
if (excludeInternal) {
    nsFilters.push(/^(config|admin|local)\./);
    nsFilters.push(/\.system\./);
}

if (nsFilters.length > 0) {
    matchStage.ns = { \$nin: nsFilters };
}

const firstDoc = oplog.find(matchStage).sort({\$natural: 1}).limit(1).toArray();
const lastDoc = oplog.find(matchStage).sort({\$natural: -1}).limit(1).toArray();

if (firstDoc.length === 0 || lastDoc.length === 0) {
    print(\`\n\${YELLOW}The oplog is empty or contains no valid DML operations after filtering.\${RESET}\`);
    quit(0);
}

const firstTime = firstDoc[0].wall;
const lastTime = lastDoc[0].wall;
const diffHours = (lastTime - firstTime) / (1000 * 60 * 60);

print(\`\n\${CYAN}\${BOLD}=== OPLOG ANALYSIS WITH DELTAS AND TIME RANGES ===\${RESET}\`);
print(\`\${BOLD}PBM Filter:      \${RESET} \${includePbm ? "INCLUDED" : "EXCLUDED"}\`);
print(\`\${BOLD}Internal DBs:    \${RESET} \${excludeInternal ? "EXCLUDED" : "INCLUDED"}\`);
print(\`\${BOLD}Start:           \${RESET} \${firstTime.toISOString().replace('T', ' ').substring(0, 19)} (UTC)\`);
print(\`\${BOLD}End:             \${RESET} \${lastTime.toISOString().replace('T', ' ').substring(0, 19)} (UTC)\`);
print(\`\${BOLD}Duration:        \${RESET} \${diffHours.toFixed(2)} hours\`);

let dateFormat = "%Y-%m-%d %H:00";
let groupDesc = "";

if (forceGroup === "day") {
    dateFormat = "%Y-%m-%d";
    groupDesc = "By DAY (Forced)";
} else if (forceGroup === "hour") {
    dateFormat = "%Y-%m-%d %H:00";
    groupDesc = "By HOUR (Forced)";
} else {
    if (diffHours > 24) {
        dateFormat = "%Y-%m-%d";
        groupDesc = "By DAY (Dynamic)";
    } else {
        dateFormat = "%Y-%m-%d %H:00";
        groupDesc = "By HOUR (Dynamic)";
    }
}

print(\`\${BOLD}Grouping:        \${RESET} \${groupDesc}\n\`);

const pipeline = [
    { \$match: matchStage },
    { \$project: {
        ns: 1,
        op: {
            \$switch: {
                branches: [
                    { case: { \$eq: ["\$op", "i"] }, then: "insert" },
                    { case: { \$eq: ["\$op", "u"] }, then: "update" },
                    { case: { \$and: [{ \$eq: ["\$op", "d"] }, { \$ne: [{ \$type: "\$lsid" }, "missing"] }] }, then: "delete" },
                    { case: { \$and: [{ \$eq: ["\$op", "d"] }, { \$eq: [{ \$type: "\$lsid" }, "missing"] }] }, then: "delete (TTL)" }
                ]
            }
        },
        doc_size: { \$bsonSize: "\$\$ROOT" },
        wall: 1,
        period: { \$dateToString: { format: dateFormat, date: "\$wall" } }
    }},
    { \$group: {
        _id: { period: "\$period", ns: "\$ns", op: "\$op" },
        total_bytes: { \$sum: "\$doc_size" },
        op_count: { \$sum: 1 },
        first_op: { \$min: "\$wall" },
        last_op: { \$max: "\$wall" }
    }},
    { \$sort: { "_id.period": 1, "total_bytes": -1 } }
];

const results = oplog.aggregate(pipeline, { allowDiskUse: true }).toArray();

const header = \`\${BOLD}\${"PERIOD".padEnd(16)} | \${"NAMESPACE".padEnd(32)} | \${"OP".padEnd(12)} | \${"FIRST OP (UTC)".padEnd(19)} | \${"LAST OP (UTC)".padEnd(19)} | \${"COUNT".padEnd(8)} | \${"Δ COUNT".padEnd(18)} | \${"SIZE (MB)".padEnd(9)} | Δ SIZE (MB)\${RESET}\`;
const separator = "-".repeat(172);

let historyData = {};
let printableRows = [];

function formatDelta(diff, pct, isSize) {
    const sign = diff > 0 ? "+" : "";
    const diffStr = isSize ? diff.toFixed(2) : diff.toString();
    const inner = \`\${sign}\${diffStr} (\${sign}\${pct.toFixed(1)}%)\`;
    
    let color = RESET;
    if (pct >= 10) color = RED;
    else if (pct <= -10) color = GREEN;
    
    return \`\${color}\${inner.padEnd(18)}\${RESET}\`;
}

// Pre-process and filter rows
results.forEach(doc => {
    const period = doc._id.period || "N/A";
    const ns = (doc._id.ns || "N/A").substring(0, 32).padEnd(32);
    const rawOp = doc._id.op || "N/A";
    const count = doc.op_count;
    const sizeMbVal = doc.total_bytes / (1024 * 1024);
    
    const firstOpStr = doc.first_op ? doc.first_op.toISOString().replace('T', ' ').substring(0, 19) : "N/A";
    const lastOpStr = doc.last_op ? doc.last_op.toISOString().replace('T', ' ').substring(0, 19) : "N/A";
    
    if (sizeMbVal < 1.0) return;

    const key = doc._id.ns + "_" + rawOp;
    const prev = historyData[key];
    
    let dCountStr = "---".padEnd(18);
    let dSizeStr = "---".padEnd(18);
    
    if (prev) {
        const diffCount = count - prev.count;
        const diffSize = sizeMbVal - prev.size;
        const pctCount = prev.count !== 0 ? (diffCount / prev.count) * 100 : 0;
        const pctSize = prev.size !== 0 ? (diffSize / prev.size) * 100 : 0;
        
        dCountStr = formatDelta(diffCount, pctCount, false);
        dSizeStr = formatDelta(diffSize, pctSize, true);
    }
    
    historyData[key] = { count: count, size: sizeMbVal };
    
    let opColor = "";
    if (rawOp === "insert") opColor = GREEN;
    else if (rawOp === "update") opColor = YELLOW;
    else if (rawOp === "delete") opColor = RED;
    else if (rawOp === "delete (TTL)") opColor = MAGENTA;
    const opStr = \`\${opColor}\${rawOp.padEnd(12)}\${RESET}\`;

    const countStr = count.toString().padEnd(8);
    const sizeStr = sizeMbVal.toFixed(2).padStart(9);

    printableRows.push({
        period: period,
        text: \`\${period.padEnd(16)} | \${ns} | \${opStr} | \${firstOpStr.padEnd(19)} | \${lastOpStr.padEnd(19)} | \${countStr} | \${dCountStr} | \${sizeStr} | \${dSizeStr}\`
    });
});

// Render Logic
if (printableRows.length === 0) {
    print(\`\n\${YELLOW}No significant operations (> 1.0 MB) were found to report in this timeframe.\${RESET}\n\`);
} else {
    print(header);
    print(separator);
    
    let currentPeriod = printableRows[0].period;
    printableRows.forEach(row => {
        if (row.period !== currentPeriod) {
            print(separator);
            currentPeriod = row.period;
        }
        print(row.text);
    });
    
    print(separator);
}
EOF

$MONGOSHBINPATH --host "$MONGOHOST" -u "$MONGOADMINUSR" -p "$MONGOADMINPAS" --authenticationDatabase "$ADMINDB" --quiet "$JS_FILE"
rm -f "$JS_FILE"