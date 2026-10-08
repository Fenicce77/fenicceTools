#!/usr/bin/env python3
"""Entry point: python3 mongo_schema_normalizer.py --help"""
import sys
from pathlib import Path

if sys.version_info < (3, 8):
    sys.exit("Python >= 3.8 is required")

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bmn.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
