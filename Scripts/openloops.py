#!/usr/bin/env python3
"""Read and update the shared Founder's Office move store."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
JSON_PATH = ROOT / "openloops.json"
CONTEXT_PATH = ROOT / "OPEN_LOOPS_CONTEXT.md"
STATUSES = ("doing", "next", "waiting", "done")
STATUS_TITLES = {
    "doing": "Doing",
    "next": "Next",
    "waiting": "Blocked",
    "done": "Done",
}
PRIORITIES = ("P0", "P1", "P2", "P3")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def load_document() -> dict:
    with JSON_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)


def find_item(document: dict, query: str, *, include_deleted: bool = False) -> dict:
    query_lower = query.lower()
    matches = [
        item
        for item in document["items"]
        if (include_deleted or not item.get("deletedAt"))
        and (
            item["id"].lower().startswith(query_lower)
            or query_lower in item["title"].lower()
        )
    ]
    if not matches:
        raise SystemExit(f"No move matches: {query}")
    if len(matches) > 1:
        titles = "\n".join(f"- {item['id'][:8]} {item['title']}" for item in matches)
        raise SystemExit(f"More than one move matches. Use an ID prefix:\n{titles}")
    return matches[0]


def save_document(document: dict) -> None:
    document["schemaVersion"] = max(document.get("schemaVersion", 1), 2)
    document["updatedAt"] = now_iso()
    JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(prefix="openloops-", suffix=".json", dir=JSON_PATH.parent)
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary_name, JSON_PATH)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    write_context(document)


def parse_due(value: str | None) -> str | None:
    if value is None:
        return None
    try:
        parsed = datetime.strptime(value, "%Y-%m-%d").replace(hour=12, tzinfo=timezone.utc)
    except ValueError as error:
        raise SystemExit("Due date must use YYYY-MM-DD.") from error
    return parsed.isoformat(timespec="seconds").replace("+00:00", "Z")


def format_due(value: str | None) -> str:
    if not value:
        return ""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.strftime("%d %b %Y").lstrip("0")


def sorted_items(items: list[dict]) -> list[dict]:
    priority_rank = {priority: index for index, priority in enumerate(PRIORITIES)}
    return sorted(
        items,
        key=lambda item: (
            priority_rank.get(item["priority"], 99),
            item.get("dueAt") is None,
            item.get("dueAt") or "",
            item["title"].lower(),
        ),
    )


def write_context(document: dict) -> None:
    updated = datetime.fromisoformat(document["updatedAt"].replace("Z", "+00:00")).astimezone()
    lines = [
        "# Founder's Office Moves",
        "",
        f"Updated: {updated.strftime('%-d %B %Y, %H:%M %Z')}",
        "",
        "> This file is generated from `openloops.json`. Use the widget or `Scripts/openloops.py` to make changes.",
        "",
    ]

    for status in STATUSES:
        items = sorted_items(
            [item for item in document["items"] if item["status"] == status and not item.get("deletedAt")]
        )
        lines.extend([f"## {STATUS_TITLES[status]} ({len(items)})", ""])
        if not items:
            lines.extend(["_None._", ""])
            continue
        for item in items:
            checkbox = "x" if status == "done" else " "
            due = f" · Due {format_due(item.get('dueAt'))}" if item.get("dueAt") else ""
            lines.append(f"- [{checkbox}] **{item['priority']}** — {item['title']}{due}")
            if item.get("details"):
                lines.append(f"  - {item['details']}")
            lines.append(f"  - ID: `{item['id'].lower()}`")
        lines.append("")

    CONTEXT_PATH.write_text("\n".join(lines), encoding="utf-8")


def command_list(document: dict, _args: argparse.Namespace) -> None:
    for status in STATUSES:
        items = sorted_items(
            [item for item in document["items"] if item["status"] == status and not item.get("deletedAt")]
        )
        print(f"{STATUS_TITLES[status].upper()} ({len(items)})")
        for item in items:
            due = f" due {format_due(item.get('dueAt'))}" if item.get("dueAt") else ""
            print(f"  {item['id'][:8]}  {item['priority']}  {item['title']}{due}")


def command_add(document: dict, args: argparse.Namespace) -> None:
    timestamp = now_iso()
    document["items"].append(
        {
            "completedAt": None,
            "createdAt": timestamp,
            "details": args.details or "",
            "deletedAt": None,
            "dueAt": parse_due(args.due),
            "id": str(uuid.uuid4()).upper(),
            "previousStatus": None,
            "priority": args.priority,
            "source": "codex-cli",
            "status": args.status,
            "title": args.title.strip(),
            "updatedAt": timestamp,
        }
    )
    save_document(document)
    print(f"Added: {args.title}")


def command_done(document: dict, args: argparse.Namespace) -> None:
    item = find_item(document, args.query)
    if item["status"] != "done":
        item["previousStatus"] = item["status"]
    item["status"] = "done"
    item["completedAt"] = now_iso()
    item["updatedAt"] = item["completedAt"]
    save_document(document)
    print(f"Completed: {item['title']}")


def command_move(document: dict, args: argparse.Namespace) -> None:
    item = find_item(document, args.query)
    old_status = item["status"]
    item["status"] = args.status
    item["updatedAt"] = now_iso()
    if args.status == "done":
        item["previousStatus"] = old_status if old_status != "done" else item.get("previousStatus")
        item["completedAt"] = item["updatedAt"]
    else:
        item["previousStatus"] = None
        item["completedAt"] = None
    save_document(document)
    print(f"Moved to {STATUS_TITLES[args.status]}: {item['title']}")


def command_delete(document: dict, args: argparse.Namespace) -> None:
    item = find_item(document, args.query)
    item["deletedAt"] = now_iso()
    item["updatedAt"] = item["deletedAt"]
    save_document(document)
    print(f"Removed (recoverable): {item['title']}")


def command_restore(document: dict, args: argparse.Namespace) -> None:
    item = find_item(document, args.query, include_deleted=True)
    if not item.get("deletedAt"):
        raise SystemExit(f"Move is not deleted: {item['title']}")
    item["deletedAt"] = None
    item["updatedAt"] = now_iso()
    save_document(document)
    print(f"Restored: {item['title']}")


def command_context(document: dict, _args: argparse.Namespace) -> None:
    write_context(document)
    print(CONTEXT_PATH)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="List every move")
    list_parser.set_defaults(handler=command_list)

    add_parser = subparsers.add_parser("add", help="Add a move")
    add_parser.add_argument("title")
    add_parser.add_argument("--status", choices=STATUSES[:-1], default="next")
    add_parser.add_argument("--priority", choices=PRIORITIES, default="P1")
    add_parser.add_argument("--due", help="Due date in YYYY-MM-DD")
    add_parser.add_argument("--details")
    add_parser.set_defaults(handler=command_add)

    done_parser = subparsers.add_parser("done", help="Complete a loop by title or ID prefix")
    done_parser.add_argument("query")
    done_parser.set_defaults(handler=command_done)

    move_parser = subparsers.add_parser("move", help="Move a loop to another status")
    move_parser.add_argument("query")
    move_parser.add_argument("status", choices=STATUSES)
    move_parser.set_defaults(handler=command_move)

    delete_parser = subparsers.add_parser("delete", help="Remove a loop from the board without erasing its history")
    delete_parser.add_argument("query")
    delete_parser.set_defaults(handler=command_delete)

    restore_parser = subparsers.add_parser("restore", help="Restore a previously removed loop")
    restore_parser.add_argument("query")
    restore_parser.set_defaults(handler=command_restore)

    context_parser = subparsers.add_parser("context", help="Regenerate the Markdown context")
    context_parser.set_defaults(handler=command_context)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    document = load_document()
    args.handler(document, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
