#!/usr/bin/env python3
"""Convert SRE Agent custom-agent YAML to dataplane v2 API JSON.

The dataplane endpoint expects an envelope shaped like:

    {"name":"...","type":"ExtendedAgent","tags":[],"owner":"", "properties":{...}}

YAML in this repository uses the authoring-friendly field names from the portal
and docs (`system_prompt`, `handoff_description`, `mcp_tools`, etc.). This helper
normalizes them to the camelCase ExtendedAgent API payload.

Usage:
    yaml-to-api-json.py <yaml_file> [output_file|-] [github_repo]

When output_file is `-`, JSON is written to stdout for piping into curl.
"""
import json
import os
import sys

import yaml


def replace_placeholders(value, github_repo):
    if not isinstance(value, str):
        return value
    if github_repo:
        return value.replace("GITHUB_REPO_PLACEHOLDER", github_repo)
    return value


def convert(yaml_file, github_repo=""):
    with open(yaml_file, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    spec = data.get("spec", data)
    instructions = replace_placeholders(
        spec.get("system_prompt", spec.get("instructions", "")), github_repo
    )
    handoff_description = replace_placeholders(
        spec.get("handoff_description", spec.get("handoffDescription", "")), github_repo
    )

    properties = {
        "instructions": instructions,
        "handoffDescription": handoff_description,
        "handoffs": spec.get("handoffs", []),
        "tools": spec.get("tools", []),
        "mcpTools": spec.get("mcp_tools", spec.get("mcpTools", [])),
        "allowParallelToolCalls": spec.get("allow_parallel_tool_calls", True),
    }

    # Current docs recommend `allowed_skills` for explicit skill access. Keep
    # `enable_skills` only when the YAML explicitly asks for the legacy toggle.
    if "allowed_skills" in spec:
        properties["allowedSkills"] = spec.get("allowed_skills", [])
    elif "enable_skills" in spec:
        properties["enableSkills"] = spec.get("enable_skills")

    return {
        "name": spec["name"],
        "type": "ExtendedAgent",
        "tags": spec.get("tags", []),
        "owner": spec.get("owner", ""),
        "properties": properties,
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: yaml-to-api-json.py <yaml_file> [output_file|-] [github_repo]", file=sys.stderr)
        return 1

    yaml_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else "-"
    github_repo = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("GITHUB_REPO", "")
    body = convert(yaml_file, github_repo)
    payload = json.dumps(body, separators=(",", ":"))

    if output_file == "-":
        print(payload)
    else:
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(payload)
        print(f"Wrote {output_file} ({len(payload)} bytes)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
