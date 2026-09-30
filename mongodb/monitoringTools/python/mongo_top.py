#!/usr/bin/env python3
import time
import os
import sys
import select
import uuid
import termios
import tty
import argparse
from pymongo import MongoClient

class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    WARN = '\033[93m'
    FAIL = '\033[91m'
    BOLD = '\033[1m'
    END = '\033[0m'

def print_help():
    help_text = f"""
{Colors.HEADER}{Colors.BOLD}=== MongoDB Live Activity Monitor (Percona 8.0.x) ==={Colors.END}

{Colors.BOLD}USAGE:{Colors.END}
  {sys.argv[0]} [OPTIONS]

{Colors.BOLD}OPTIONS:{Colors.END}
  {Colors.GREEN}-d, --delay{Colors.END}    Refresh delay in seconds (Default: 2 if omitted or left empty)
  {Colors.GREEN}-u, --user{Colors.END}     Initial filter for users, comma-separated (Default: ALL)
  {Colors.GREEN}-t, --time{Colors.END}     Initial filter for minimum execution time in seconds (Default: 0)
  {Colors.GREEN}-c, --config{Colors.END}   Path to custom config file (Default: searches locally for mongo_config.conf)
  {Colors.GREEN}-h, --help{Colors.END}     Show this colored help message and exit

{Colors.BOLD}EXAMPLES:{Colors.END}
  {sys.argv[0]} -d        (Starts with default 2s delay)
  {sys.argv[0]} -d 5      (Starts with 5s delay)
  {sys.argv[0]} --user appUser1,appUser2 --time 5 -d
"""
    print(help_text)

def find_config(custom_path=None):
    if custom_path and os.path.exists(custom_path):
        return custom_path
    paths = [
        "mongo_config.conf",
        os.path.join(os.getcwd(), "mongo_config.conf"),
        os.path.join(os.path.dirname(os.path.realpath(__file__)), "mongo_config.conf")
    ]
    for path in paths:
        if os.path.exists(path):
            return path
    return None

def parse_config(config_path):
    config = {}
    with open(config_path, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            if "=" in line:
                key, val = line.split("=", 1)
                config[key] = val.strip('"').strip("'").strip('`')
    return config

def get_single_keypress(timeout):
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        i, _, _ = select.select([sys.stdin], [], [], timeout)
        if i:
            return sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return None

def main():
    if len(sys.argv) == 1 or '-h' in sys.argv or '--help' in sys.argv:
        print_help()
        sys.exit(0)

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('-d', '--delay', type=int, nargs='?', const=2, default=2)
    parser.add_argument('-u', '--user', type=str, default="")
    parser.add_argument('-t', '--time', type=int, default=0)
    parser.add_argument('-c', '--config', type=str, default=None)
    
    try:
        args = parser.parse_args()
    except SystemExit:
        print_help()
        sys.exit(1)

    config_path = find_config(args.config)
    if not config_path:
        print(f"{Colors.FAIL}Error: mongo_config.conf not found.{Colors.END}")
        sys.exit(1)

    conf = parse_config(config_path)
    try:
        replset_name, nodes = conf.get("MONGOHOST", "").split("/", 1)
    except ValueError:
        print(f"{Colors.FAIL}Error: MONGOHOST must be 'replSetName/node1,node2'{Colors.END}")
        sys.exit(1)

    uri = f"mongodb://{conf.get('MONGOADMINUSR')}:{conf.get('MONGOADMINPAS')}@{nodes}/?authSource={conf.get('ADMINDB')}&replicaSet={replset_name}"
    
    try:
        client = MongoClient(uri, serverSelectionTimeoutMS=5000)
        client.admin.command('ping')
    except Exception as e:
        print(f"{Colors.FAIL}Connection failed: {e}{Colors.END}")
        sys.exit(1)

    filter_user = args.user
    min_time = args.time
    delay = args.delay

    IGNORED_USERS = {"system", "__system"}

    while True:
        try:
            os.system('cls' if os.name == 'nt' else 'clear')
            
            pipeline = [
                {"$currentOp": {"allUsers": True, "idleConnections": False, "localOps": True}},
                {"$match": {"active": True, "ns": {"$ne": "admin.$cmd"}}}
            ]
            
            ops = list(client.admin.aggregate(pipeline))

            # --- MULTI-USER PARSING ---
            target_users = [u.strip().lower() for u in filter_user.split(',')] if filter_user else []
            display_users = ", ".join(target_users) if target_users else "ALL"

            print(f"{Colors.HEADER}{Colors.BOLD}=== MongoDB Live Activity Monitor (Percona 8.0.x) ==={Colors.END}")
            print(f"Users Filter: {Colors.GREEN}{display_users}{Colors.END} | "
                  f"Min Time: {Colors.GREEN}{min_time}s{Colors.END} | "
                  f"Refresh: {Colors.GREEN}{delay}s{Colors.END}")
            print("-" * 160)
            print(f"{Colors.BOLD}{'OPID':<10} | {'USER':<15} | {'TIME(s)':<7} | {'NAMESPACE':<38} | {'TRX ID':<36} | {'WAITING':<7} | {'COMMAND'}{Colors.END}")
            print("-" * 160)

            for op in ops:
                eff_users = op.get("effectiveUsers", [])
                db_user = eff_users[0].get("user", "System") if eff_users else "System"
                
                if db_user.lower() in IGNORED_USERS: continue

                secs_running = op.get("secs_running", 0)

                # --- MULTI-USER FILTER LOGIC ---
                if target_users and db_user.lower() not in target_users: continue
                if secs_running < min_time: continue

                opid = str(op.get("opid", ""))
                raw_ns = op.get("ns", "")
                ns = (raw_ns[:35] + '...') if len(raw_ns) > 38 else raw_ns
                
                lsid_obj = op.get("lsid", {}).get("id")
                trx_id = "None"
                if lsid_obj:
                    try:
                        if isinstance(lsid_obj, uuid.UUID): trx_id = str(lsid_obj)
                        elif isinstance(lsid_obj, bytes): trx_id = str(uuid.UUID(bytes=lsid_obj))
                        else: trx_id = str(lsid_obj)
                    except: trx_id = str(lsid_obj)
                
                is_waiting = op.get("waitingForLock", False)
                wait_str = f"{Colors.FAIL}YES{Colors.END}    " if is_waiting else f"{Colors.GREEN}NO{Colors.END}     "
                
                command = op.get("command", {})
                cmd_str = str(command)[:45] + "..." if command else "N/A"

                print(f"{opid:<10} | {Colors.BLUE}{db_user:<15}{Colors.END} | {secs_running:<7} | {ns:<38} | {trx_id:<36} | {wait_str} | {cmd_str}")

            print("-" * 160)
            print(f"{Colors.BOLD}Interactive Menu (Press Key):{Colors.END} [{Colors.WARN}u{Colors.END}] Set User | [{Colors.WARN}t{Colors.END}] Min Time | [{Colors.WARN}d{Colors.END}] Delay | [{Colors.WARN}q{Colors.END}] Quit\n")

            choice = get_single_keypress(delay)
            
            if choice:
                choice = choice.lower()
                print() 
                if choice == 'u':
                    filter_user = input(f"{Colors.WARN}Enter users to monitor (comma-separated, blank for all): {Colors.END}").strip()
                elif choice == 't':
                    try: min_time = int(input(f"{Colors.WARN}Enter minimum connection time (seconds): {Colors.END}").strip())
                    except ValueError: pass
                elif choice == 'd':
                    try: delay = int(input(f"{Colors.WARN}Enter refresh delay (seconds): {Colors.END}").strip())
                    except ValueError: pass
                elif choice == 'q':
                    print(f"{Colors.GREEN}Exiting gracefully...{Colors.END}")
                    break

        except KeyboardInterrupt:
            print(f"\n{Colors.GREEN}Exiting gracefully...{Colors.END}")
            break
        except Exception as e:
            print(f"\n{Colors.FAIL}Error: {e}{Colors.END}")
            time.sleep(delay)

if __name__ == "__main__":
    main()