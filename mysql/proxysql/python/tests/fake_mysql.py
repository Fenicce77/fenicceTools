#!/usr/bin/env python3
"""Protocol-aware fake MySQL CLI used by transport tests."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

RESPONSES = {
    "TEST_CONNECTIONS": "app\tclient\tbackend:3306\tappdb\t4",
    "TEST_SECOND_SAMPLE": "app\tclient\tbackend:3306\tappdb\t6",
    "SELECT @@version": "2.7.3",
    "SELECT @@hostname": "proxysql-test",
}


def main() -> int:
    state_dir = Path(os.environ["FAKE_MYSQL_STATE_DIR"])
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / "launches").open("a", encoding="utf-8") as launches:
        launches.write(f"{os.getpid()}\n")

    stderr_count = int(os.environ.get("FAKE_MYSQL_STDERR_LINES", "0"))
    for index in range(stderr_count):
        print(f"fake stderr {index}", file=sys.stderr, flush=True)

    exit_token = os.environ.get("FAKE_MYSQL_EXIT_ON_TOKEN", "")
    drop_requested = os.environ.get("FAKE_MYSQL_DROP_END_ON_FIRST_LAUNCH") == "1"
    drop_marker = state_dir / "drop_done"

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if exit_token and exit_token in line:
            return 2
        marker_match = re.search(r"'(__PXMON_(?:BEGIN|END)_\d+__)'", line)
        if marker_match:
            marker = marker_match.group(1)
            if "_END_" in marker and drop_requested and not drop_marker.exists():
                drop_marker.touch()
                continue
            print(marker, flush=True)
            continue
        for token, response in RESPONSES.items():
            if token in line:
                print(response, flush=True)
                break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
