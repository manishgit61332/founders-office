#!/usr/bin/env python3
"""Focused regression checks for planning edits in the shared move CLI."""

from __future__ import annotations

import argparse
import importlib.util
import json
import tempfile
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("openloops.py")
SPEC = importlib.util.spec_from_file_location("founder_office_openloops", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT_PATH}")
openloops = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(openloops)


def planning_args(
    *,
    query: str = "editable",
    priority: str | None = None,
    due: str | None = None,
    clear_due: bool = False,
) -> argparse.Namespace:
    return argparse.Namespace(
        query=query,
        priority=priority,
        due=due,
        clear_due=clear_due,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="founder-office-cli-test-") as directory:
        root = Path(directory)
        openloops.JSON_PATH = root / "openloops.json"
        openloops.CONTEXT_PATH = root / "OPEN_LOOPS_CONTEXT.md"
        document = {
            "schemaVersion": 2,
            "updatedAt": "2026-08-31T00:00:00Z",
            "items": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "title": "Editable move",
                    "details": "",
                    "status": "next",
                    "previousStatus": None,
                    "priority": "P2",
                    "dueAt": None,
                    "createdAt": "2026-08-31T00:00:00Z",
                    "updatedAt": "2026-08-31T00:00:00Z",
                    "completedAt": None,
                    "deletedAt": None,
                    "source": "test",
                },
                {
                    "id": "00000000-0000-0000-0000-000000000002",
                    "title": "App canonical move",
                    "details": "",
                    "status": "next",
                    "previousStatus": None,
                    "priority": "P1",
                    "dueAt": "2026-09-15T12:00:00Z",
                    "createdAt": "2026-08-31T00:00:00Z",
                    "updatedAt": "2026-08-31T00:00:00Z",
                    "completedAt": None,
                    "deletedAt": None,
                    "source": "founder-office-mac",
                }
            ],
        }
        openloops.JSON_PATH.write_text(json.dumps(document), encoding="utf-8")

        openloops.command_edit(document, planning_args(priority="P0", due="2026-09-12"))
        updated = openloops.load_document()
        item = updated["items"][0]
        assert updated["schemaVersion"] == 3
        assert item["priority"] == "P0"
        assert item["dueAt"] == "2026-09-12T12:00:00Z"
        assert item["priorityUpdatedAt"] == item["dueAtUpdatedAt"]
        priority_clock = item["priorityUpdatedAt"]
        assert "**P0** — Editable move · Due 12 Sep 2026" in openloops.CONTEXT_PATH.read_text()

        persisted_bytes = openloops.JSON_PATH.read_bytes()
        openloops.command_edit(updated, planning_args(priority="P0", due="2026-09-12"))
        assert openloops.JSON_PATH.read_bytes() == persisted_bytes

        openloops.command_edit(updated, planning_args(clear_due=True))
        cleared = openloops.load_document()["items"][0]
        assert cleared["priority"] == "P0"
        assert cleared["dueAt"] is None
        assert cleared["priorityUpdatedAt"] == priority_clock
        assert cleared["dueAtUpdatedAt"] is not None

        document_with_cleared_deadline = openloops.load_document()
        persisted_bytes = openloops.JSON_PATH.read_bytes()
        openloops.command_edit(
            document_with_cleared_deadline,
            planning_args(query="app canonical", due="2026-09-15"),
        )
        assert openloops.JSON_PATH.read_bytes() == persisted_bytes


if __name__ == "__main__":
    main()
