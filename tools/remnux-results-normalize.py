#!/usr/bin/env python3
"""Normalize REMnux/Salt installer result YAML files for stable diffs.

The REMnux installer writes Salt highstate results where volatile fields such as
run number, duration, and start time make raw diffs noisy. This tool extracts
only failed states and emits a stable JSON or Markdown representation. It can
also compare two reports and show new, fixed, unchanged, and changed failures.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - depends on target host environment
    yaml = None


VOLATILE_FIELDS = {"__run_num__", "duration", "start_time", "changes"}
REQUISITE_RE = re.compile(r"One or more requisite failed:\s*(.+)", re.I)
SYSTEMD_RUN_RE = re.compile(
    r"Running as unit:\s+run-[0-9A-Za-z]+\.scope;\s+invocation ID:\s+[0-9A-Za-z]+\s+",
    re.I,
)
APPORT_MAXREPORTS_RE = re.compile(
    r"(?:No apport report written because MaxReports is reached already\s*)+",
    re.I,
)
CATEGORY_ORDER = {"direct-failure": 0, "requisite-cascade": 1}


def die(message: str, exit_code: int = 1) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(exit_code)


def normalize_ws(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def normalize_requisite_comment(comment: str) -> str:
    match = REQUISITE_RE.search(comment)
    if not match:
        return comment

    requisites = sorted(
        set(part.strip() for part in match.group(1).split(",") if part.strip())
    )
    if not requisites:
        return comment

    return f"{comment[:match.start(1)]}{', '.join(requisites)}{comment[match.end(1):]}"


def normalize_comment(value: Any) -> str:
    comment = normalize_ws(value)
    comment = SYSTEMD_RUN_RE.sub("", comment)
    comment = APPORT_MAXREPORTS_RE.sub("", comment)
    comment = normalize_requisite_comment(comment)
    return normalize_ws(comment)


def parse_state_key(state_key: str) -> dict[str, str]:
    parts = state_key.split("_|-")
    if len(parts) == 4:
        return {
            "state": parts[0],
            "key_id": parts[1],
            "key_name": parts[2],
            "function": parts[3],
        }
    return {
        "state": "",
        "key_id": "",
        "key_name": "",
        "function": "",
    }


def load_input(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        if path.suffix.lower() == ".json":
            loaded = json.load(handle)
        else:
            if yaml is None:
                die("PyYAML is required for YAML input. Install it with: python3 -m pip install pyyaml")
            loaded = yaml.safe_load(handle)
    if not isinstance(loaded, dict):
        die(f"{path} did not parse as a mapping")
    return loaded


def is_normalized_report(report: dict[str, Any]) -> bool:
    failures = report.get("failures")
    return isinstance(failures, list) and all(
        isinstance(item, dict) and "stable_key" in item for item in failures
    )


def normalize_existing_report(path: Path, report: dict[str, Any]) -> dict[str, Any]:
    failures = []
    for item in report.get("failures", []):
        normalized = dict(item)
        normalized.pop("failed_requisite", None)
        normalized["comment"] = normalize_comment(normalized.get("comment"))
        requisite_match = REQUISITE_RE.search(normalized["comment"])
        if requisite_match:
            normalized["failed_requisite"] = requisite_match.group(1).strip()
            normalized["category"] = "requisite-cascade"
        else:
            normalized["category"] = "direct-failure"
        failures.append(normalized)
    failures.sort(key=lambda item: (CATEGORY_ORDER.get(item["category"], 99), item["stable_key"]))
    return {
        "source": str(path),
        "original_source": report.get("source", ""),
        "failed_count": len(failures),
        "direct_failures": sum(1 for item in failures if item["category"] == "direct-failure"),
        "requisite_cascades": sum(1 for item in failures if item["category"] == "requisite-cascade"),
        "failures": failures,
    }


def iter_state_results(report: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    local = report.get("local")
    if isinstance(local, dict):
        root = local
    else:
        root = report

    items: list[tuple[str, dict[str, Any]]] = []
    for state_key, state_result in root.items():
        if isinstance(state_result, dict):
            items.append((str(state_key), state_result))
    return items


def normalize_failure(state_key: str, state_result: dict[str, Any]) -> dict[str, Any]:
    parsed = parse_state_key(state_key)
    comment = normalize_comment(state_result.get("comment"))
    requisite_match = REQUISITE_RE.search(comment)

    sls = normalize_ws(state_result.get("__sls__"))
    state_id = normalize_ws(state_result.get("__id__") or parsed["key_id"])
    name = normalize_ws(state_result.get("name") or parsed["key_name"])
    state = parsed["state"]
    function = parsed["function"]

    stable_key = "|".join([sls, state_id, state, function, name])
    category = "requisite-cascade" if requisite_match else "direct-failure"

    record: dict[str, Any] = {
        "stable_key": stable_key,
        "category": category,
        "sls": sls,
        "id": state_id,
        "state": state,
        "function": function,
        "name": name,
        "comment": comment,
        "raw_state_key": state_key,
    }
    if requisite_match:
        record["failed_requisite"] = requisite_match.group(1).strip()

    for field, value in state_result.items():
        if field.startswith("__") or field in VOLATILE_FIELDS:
            continue
        if field in {"comment", "name", "result"}:
            continue
        if isinstance(value, (str, int, float, bool)) or value is None:
            record[field] = value

    return record


def normalize_report(path: Path) -> dict[str, Any]:
    report = load_input(path)
    if is_normalized_report(report):
        return normalize_existing_report(path, report)

    failures = [
        normalize_failure(state_key, state_result)
        for state_key, state_result in iter_state_results(report)
        if state_result.get("result") is False
    ]
    failures.sort(key=lambda item: (CATEGORY_ORDER.get(item["category"], 99), item["stable_key"]))

    return {
        "source": str(path),
        "failed_count": len(failures),
        "direct_failures": sum(1 for item in failures if item["category"] == "direct-failure"),
        "requisite_cascades": sum(1 for item in failures if item["category"] == "requisite-cascade"),
        "failures": failures,
    }


def compare_reports(old_report: dict[str, Any], new_report: dict[str, Any]) -> dict[str, Any]:
    old_map = {item["stable_key"]: item for item in old_report["failures"]}
    new_map = {item["stable_key"]: item for item in new_report["failures"]}

    old_keys = set(old_map)
    new_keys = set(new_map)
    still_keys = old_keys & new_keys

    changed = []
    unchanged = []
    for key in sorted(still_keys):
        old_item = old_map[key]
        new_item = new_map[key]
        if old_item.get("comment") != new_item.get("comment") or old_item.get("category") != new_item.get("category"):
            changed.append({"old": old_item, "new": new_item})
        else:
            unchanged.append(new_item)

    return {
        "old_source": old_report["source"],
        "new_source": new_report["source"],
        "old_failed_count": old_report["failed_count"],
        "new_failed_count": new_report["failed_count"],
        "new_failures": [new_map[key] for key in sorted(new_keys - old_keys)],
        "fixed_failures": [old_map[key] for key in sorted(old_keys - new_keys)],
        "changed_failures": changed,
        "unchanged_failures": unchanged,
    }


def render_failures_markdown(report: dict[str, Any]) -> str:
    lines = [
        f"# REMnux Failed States",
        "",
        f"Source: `{report['source']}`",
        "",
        f"- Failed states: {report['failed_count']}",
        f"- Direct failures: {report['direct_failures']}",
        f"- Requisite cascades: {report['requisite_cascades']}",
        "",
    ]
    for category, title in (
        ("direct-failure", "Direct failures"),
        ("requisite-cascade", "Requisite cascades"),
    ):
        items = [item for item in report["failures"] if item["category"] == category]
        lines.extend([f"## {title}", ""])
        if not items:
            lines.extend(["None.", ""])
            continue
        for item in items:
            lines.extend(
                [
                    f"### {item['sls']} :: {item['id']}",
                    "",
                    f"- State: `{item['state']}.{item['function']}`",
                    f"- Name: `{item['name']}`",
                    f"- Stable key: `{item['stable_key']}`",
                    f"- Comment: {item['comment']}",
                    "",
                ]
            )
    return "\n".join(lines).rstrip() + "\n"


def render_compare_markdown(compare: dict[str, Any]) -> str:
    lines = [
        "# REMnux Failed State Comparison",
        "",
        f"- Old: `{compare['old_source']}` ({compare['old_failed_count']} failures)",
        f"- New: `{compare['new_source']}` ({compare['new_failed_count']} failures)",
        f"- New failures: {len(compare['new_failures'])}",
        f"- Fixed failures: {len(compare['fixed_failures'])}",
        f"- Changed failures: {len(compare['changed_failures'])}",
        f"- Unchanged failures: {len(compare['unchanged_failures'])}",
        "",
    ]

    def add_section(title: str, items: list[dict[str, Any]]) -> None:
        lines.extend([f"## {title}", ""])
        if not items:
            lines.extend(["None.", ""])
            return
        for item in items:
            lines.extend(
                [
                    f"- `{item['sls']}` :: `{item['id']}`",
                    f"  - `{item['state']}.{item['function']}` `{item['name']}`",
                    f"  - {item['comment']}",
                ]
            )
        lines.append("")

    add_section("New failures", compare["new_failures"])
    add_section("Fixed failures", compare["fixed_failures"])

    lines.extend(["## Changed failures", ""])
    if not compare["changed_failures"]:
        lines.extend(["None.", ""])
    else:
        for pair in compare["changed_failures"]:
            old = pair["old"]
            new = pair["new"]
            lines.extend(
                [
                    f"- `{new['sls']}` :: `{new['id']}`",
                    f"  - Old: {old['comment']}",
                    f"  - New: {new['comment']}",
                ]
            )
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def write_output(content: str, output_path: Path | None) -> None:
    if output_path:
        output_path.write_text(content, encoding="utf-8")
        return
    try:
        print(content, end="")
        sys.stdout.flush()
    except BrokenPipeError:
        # Reader (e.g. `head`) closed the pipe; point stdout at devnull so the
        # interpreter's shutdown flush doesn't raise a second error.
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        raise SystemExit(0)


def configure_stdout() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def main(argv: list[str] | None = None) -> int:
    configure_stdout()
    parser = argparse.ArgumentParser(
        description="Normalize or compare REMnux/Salt installer result YAML failures."
    )
    parser.add_argument("report", type=Path, help="YAML result file to normalize, or old report when using --compare")
    parser.add_argument("--compare", type=Path, metavar="NEW_REPORT", help="Compare REPORT against NEW_REPORT")
    parser.add_argument("--format", choices=("json", "markdown"), default="json", help="Output format")
    parser.add_argument("-o", "--out", type=Path, help="Write output to this file instead of stdout")
    args = parser.parse_args(argv)

    if args.compare:
        result = compare_reports(normalize_report(args.report), normalize_report(args.compare))
        if args.format == "markdown":
            write_output(render_compare_markdown(result), args.out)
        else:
            write_output(json.dumps(result, indent=2, sort_keys=True) + "\n", args.out)
    else:
        result = normalize_report(args.report)
        if args.format == "markdown":
            write_output(render_failures_markdown(result), args.out)
        else:
            write_output(json.dumps(result, indent=2, sort_keys=True) + "\n", args.out)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
