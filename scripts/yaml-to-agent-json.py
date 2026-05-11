#!/usr/bin/env python3
"""Compatibility wrapper for yaml-to-api-json.py.

Usage:
    yaml-to-agent-json.py <yaml_file> [github_repo]

Outputs JSON to stdout suitable for:
    PUT /api/v2/extendedAgent/agents/{name}
"""
import json
import sys
import importlib.util
from pathlib import Path

converter_path = Path(__file__).resolve().with_name("yaml-to-api-json.py")
spec = importlib.util.spec_from_file_location("yaml_to_api_json", converter_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: yaml-to-agent-json.py <yaml_file> [github_repo]", file=sys.stderr)
        sys.exit(1)

    repo = sys.argv[2] if len(sys.argv) > 2 else ""
    print(json.dumps(module.convert(sys.argv[1], repo), separators=(",", ":")))
