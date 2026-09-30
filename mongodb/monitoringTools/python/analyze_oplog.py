#!/usr/bin/env python3
import sys
import os
import re
import argparse
from pymongo import MongoClient

class Colors:
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    MAGENTA = '\033[95m'
    BOLD = '\033[1m'
    RESET = '\033[0m'

def show_help():
    script_name = os.path.basename(sys.argv[0])
    print(f"\n{Colors.CYAN}{Colors.BOLD}=== MONGODB OPLOG ANALYZER ==={Colors.RESET}\n")
    print(f"{Colors.BOLD}DESCRIPTION:{Colors.RESET}")
    print("  Analyzes the MongoDB oplog to identify which operations and namespaces")
    print("  are consuming the most space, highlighting trends, time ranges, and TTL deletes.\n")
    print(f"{Colors.BOLD}USAGE:{Colors.RESET}")
    print(f"  python3 {script_name} <config_file> [options]\n")
    print(f"{Colors.BOLD}ARGUMENTS:{Colors.RESET}")
    print(f"  {Colors.YELLOW}<config_file>{Colors.RESET}         Path to the MongoDB configuration file.\n")
    print(f"{Colors.BOLD}OPTIONS:{Colors.RESET}")
    print(f"  {Colors.GREEN}--include-pbm{Colors.RESET}         Include Percona Backup for MongoDB (admin.pbm*) collections.")
    print(f"  {Colors.GREEN}--exclude-internal{Colors.RESET}    Exclude native MongoDB DBs/collections (config, admin, local, system).")
    print(f"  {Colors.GREEN}--group <hour|day>{Colors.RESET}    Force grouping by 'hour' or 'day'. Adapts dynamically if omitted.\n")
    print(f"{Colors.BOLD}EXAMPLES:{Colors.RESET}")
    print(f"  python3 {script_name} mongo_config.conf")
    print(f"  python3 {script_name} mongo_config.conf --exclude-internal")
    print(f"  python3 {script_name} mongo_config.conf --group hour\n")
    sys.exit(0)

def build_uri_from_config(config_path):
    config = {}
    if not os.path.isfile(config_path):
        print(f"{Colors.RED}Error: Configuration file '{config_path}' not found.{Colors.RESET}")
        sys.exit(1)

    with open(config_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'): continue
            if line.startswith('export '): line = line.replace('export ', '', 1)
            if '=' in line:
                key, value = line.split('=', 1)
                config[key.strip()] = value.strip(' "\'')

    host_parts = config['MONGOHOST'].split('/')
    if len(host_parts) == 2:
        return f"mongodb://{config['MONGOADMINUSR']}:{config['MONGOADMINPAS']}@{host_parts[1]}/?replicaSet={host_parts[0]}&authSource={config['ADMINDB']}"
    return f"mongodb://{config['MONGOADMINUSR']}:{config['MONGOADMINPAS']}@{config['MONGOHOST']}/?authSource={config['ADMINDB']}"

def format_delta(diff, pct, is_size=False):
    sign = "+" if diff > 0 else ""
    diff_val = f"{diff:.2f}" if is_size else f"{diff}"
    inner_str = f"{sign}{diff_val} ({sign}{pct:.1f}%)"
    
    if pct >= 10: color = Colors.RED
    elif pct <= -10: color = Colors.GREEN
    else: color = Colors.RESET
        
    padded_str = f"{inner_str:<18}"
    return f"{color}{padded_str}{Colors.RESET}"

def analyze_oplog(config_file, include_pbm, exclude_internal, group_by):
    mongo_uri = build_uri_from_config(config_file)

    try:
        client = MongoClient(mongo_uri)
        oplog = client["local"]["oplog.rs"]

        match_query = {"op": {"$in": ["i", "u", "d"]}}
        ns_nin_filters = []
        
        if not include_pbm:
            ns_nin_filters.append(re.compile(r"^admin\.pbm"))
            
        if exclude_internal:
            ns_nin_filters.append(re.compile(r"^(config|admin|local)\."))
            ns_nin_filters.append(re.compile(r"\.system\."))
            
        if ns_nin_filters:
            match_query["ns"] = {"$nin": ns_nin_filters}

        first_doc = list(oplog.find(match_query).sort([("$natural", 1)]).limit(1))
        last_doc = list(oplog.find(match_query).sort([("$natural", -1)]).limit(1))

        if not first_doc or not last_doc:
            print(f"{Colors.YELLOW}The oplog is empty or contains no valid DML operations after filtering.{Colors.RESET}")
            return

        first_time = first_doc[0].get("wall")
        last_time = last_doc[0].get("wall")
        diff_hours = (last_time - first_time).total_seconds() / 3600

        print(f"\n{Colors.CYAN}{Colors.BOLD}=== OPLOG ANALYSIS WITH DELTAS AND TIME RANGES ==={Colors.RESET}")
        print(f"{Colors.BOLD}PBM Filter:      {Colors.RESET} {'INCLUDED' if include_pbm else 'EXCLUDED'}")
        print(f"{Colors.BOLD}Internal DBs:    {Colors.RESET} {'EXCLUDED' if exclude_internal else 'INCLUDED'}")
        print(f"{Colors.BOLD}Start:           {Colors.RESET} {first_time.strftime('%Y-%m-%d %H:%M:%S')} (UTC)")
        print(f"{Colors.BOLD}End:             {Colors.RESET} {last_time.strftime('%Y-%m-%d %H:%M:%S')} (UTC)")
        print(f"{Colors.BOLD}Duration:        {Colors.RESET} {diff_hours:.2f} hours")

        if group_by == "day":
            print(f"{Colors.BOLD}Grouping:        {Colors.RESET} By DAY (Forced)\n")
            date_format = "%Y-%m-%d"
        elif group_by == "hour":
            print(f"{Colors.BOLD}Grouping:        {Colors.RESET} By HOUR (Forced)\n")
            date_format = "%Y-%m-%d %H:00"
        else:
            if diff_hours > 24:
                print(f"{Colors.BOLD}Grouping:        {Colors.RESET} By DAY (Dynamic)\n")
                date_format = "%Y-%m-%d"
            else:
                print(f"{Colors.BOLD}Grouping:        {Colors.RESET} By HOUR (Dynamic)\n")
                date_format = "%Y-%m-%d %H:00"

        print(f"{Colors.CYAN}Analyzing trends and timings...{Colors.RESET}\n")

        pipeline = [
            {"$match": match_query},
            {"$project": {
                "ns": 1,
                "op": {
                    "$switch": {
                        "branches": [
                            {"case": {"$eq": ["$op", "i"]}, "then": "insert"},
                            {"case": {"$eq": ["$op", "u"]}, "then": "update"},
                            {"case": {"$and": [{"$eq": ["$op", "d"]}, {"$ne": [{"$type": "$lsid"}, "missing"]}]}, "then": "delete"},
                            {"case": {"$and": [{"$eq": ["$op", "d"]}, {"$eq": [{"$type": "$lsid"}, "missing"]}]}, "then": "delete (TTL)"}
                        ]
                    }
                },
                "doc_size": {"$bsonSize": "$$ROOT"},
                "wall": 1,
                "period": {"$dateToString": {"format": date_format, "date": "$wall"}}
            }},
            {"$group": {
                "_id": {"period": "$period", "ns": "$ns", "op": "$op"},
                "total_bytes": {"$sum": "$doc_size"},
                "op_count": {"$sum": 1},
                "first_op": {"$min": "$wall"},
                "last_op": {"$max": "$wall"}
            }},
            {"$sort": {"_id.period": 1, "total_bytes": -1}},
        ]

        results = list(oplog.aggregate(pipeline, allowDiskUse=True))

        printable_rows = []
        history_data = {}

        for doc in results:
            period = doc["_id"].get("period", "N/A")
            ns = doc["_id"].get("ns", "N/A")
            raw_op = doc["_id"].get("op", "N/A")
            count = doc["op_count"]
            size_mb = doc["total_bytes"] / (1024 * 1024)
            first_op_time = doc["first_op"].strftime('%Y-%m-%d %H:%M:%S') if doc.get("first_op") else "N/A"
            last_op_time = doc["last_op"].strftime('%Y-%m-%d %H:%M:%S') if doc.get("last_op") else "N/A"
            
            # Filter noise
            if size_mb < 1.0: 
                continue

            # Calculate deltas
            key = f"{ns}_{raw_op}"
            prev = history_data.get(key)
            
            d_count_str = f"{'---':<18}"
            d_size_str = f"{'---':<18}"
            
            if prev:
                diff_count = count - prev["count"]
                diff_size = size_mb - prev["size"]
                pct_count = (diff_count / prev["count"] * 100) if prev["count"] else 0
                pct_size = (diff_size / prev["size"] * 100) if prev["size"] else 0
                
                d_count_str = format_delta(diff_count, pct_count, is_size=False)
                d_size_str = format_delta(diff_size, pct_size, is_size=True)
                
            history_data[key] = {"count": count, "size": size_mb}
            
            # Colors
            if raw_op == "insert": op_str = f"{Colors.GREEN}{raw_op:<12}{Colors.RESET}"
            elif raw_op == "update": op_str = f"{Colors.YELLOW}{raw_op:<12}{Colors.RESET}"
            elif raw_op == "delete": op_str = f"{Colors.RED}{raw_op:<12}{Colors.RESET}"
            elif raw_op == "delete (TTL)": op_str = f"{Colors.MAGENTA}{raw_op:<12}{Colors.RESET}"
            else: op_str = f"{raw_op:<12}"

            # Save the formatted string for later printing
            printable_rows.append({
                "period": period,
                "text": f"{period:<16} | {ns:<32} | {op_str} | {first_op_time:<19} | {last_op_time:<19} | {count:<8} | {d_count_str} | {size_mb:>9,.2f} | {d_size_str}"
            })

        # Render Logic
        if not printable_rows:
            print(f"{Colors.YELLOW}No significant operations (> 1.0 MB) were found to report in this timeframe.{Colors.RESET}\n")
            return

        header = f"{'PERIOD':<16} | {'NAMESPACE':<32} | {'OP':<12} | {'FIRST OP (UTC)':<19} | {'LAST OP (UTC)':<19} | {'COUNT':<8} | {'Δ COUNT':<18} | {'SIZE (MB)':<9} | {'Δ SIZE (MB)':<18}"
        separator = "-" * 172
        
        print(f"{Colors.BOLD}{header}{Colors.RESET}")
        print(separator)
        
        current_period = printable_rows[0]["period"]
        for row in printable_rows:
            if row["period"] != current_period:
                print(separator)
                current_period = row["period"]
            print(row["text"])
        print(separator)

    except Exception as e:
        print(f"{Colors.RED}Critical Error: {e}{Colors.RESET}")

if __name__ == "__main__":
    if len(sys.argv) == 1 or "-h" in sys.argv or "--help" in sys.argv:
        show_help()

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("config", help="Path to the configuration file.")
    parser.add_argument("--include-pbm", action="store_true", help="Include Percona Backup for MongoDB collections.")
    parser.add_argument("--exclude-internal", action="store_true", help="Exclude native MongoDB DBs/collections.")
    parser.add_argument("--group", choices=["hour", "day"], default=None, help="Force grouping by 'hour' or 'day'.")
    
    args = parser.parse_args()
    analyze_oplog(args.config, args.include_pbm, args.exclude_internal, args.group)