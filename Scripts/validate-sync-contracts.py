#!/usr/bin/env python3
"""Validate the credential-free v1 sync contracts without third-party packages."""

from __future__ import annotations

import copy
import json
import re
import sys
import unicodedata
import uuid
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_ROOT = ROOT / "contracts" / "v1"
SCHEMA_ROOT = CONTRACT_ROOT / "schemas"
MIGRATION_ROOT = ROOT / "supabase" / "migrations"
PGTAP_PATH = ROOT / "supabase" / "tests" / "001_sync_rls_and_rpc.test.sql"
SWIFT_CONTRACT_PATH = ROOT / "Sources" / "FounderOfficeCore" / "AccountSyncContracts.swift"


class ContractError(Exception):
    pass


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"), parse_float=Decimal)
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot parse {path.relative_to(ROOT)}: {error}") from error


class SchemaValidator:
    def __init__(self) -> None:
        self.documents: dict[Path, Any] = {}

    def document(self, path: Path) -> Any:
        path = path.resolve()
        if path not in self.documents:
            self.documents[path] = load_json(path)
        return self.documents[path]

    def resolve(self, reference: str, document_path: Path) -> tuple[Any, Path]:
        file_part, separator, fragment = reference.partition("#")
        target_path = (document_path.parent / file_part).resolve() if file_part else document_path.resolve()
        target = self.document(target_path)
        if separator and fragment:
            if not fragment.startswith("/"):
                raise ContractError(f"unsupported JSON pointer in {reference!r}")
            for raw_token in fragment[1:].split("/"):
                token = raw_token.replace("~1", "/").replace("~0", "~")
                try:
                    target = target[int(token)] if isinstance(target, list) else target[token]
                except (KeyError, IndexError, ValueError, TypeError) as error:
                    raise ContractError(f"unresolved schema reference {reference!r}") from error
        return target, target_path

    def check_references(self, value: Any, document_path: Path) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "$ref":
                    self.resolve(child, document_path)
                else:
                    self.check_references(child, document_path)
        elif isinstance(value, list):
            for child in value:
                self.check_references(child, document_path)

    def validate(self, instance: Any, schema: dict[str, Any], document_path: Path, location: str = "$") -> None:
        if "$ref" in schema:
            target, target_path = self.resolve(schema["$ref"], document_path)
            self.validate(instance, target, target_path, location)

        if "const" in schema and instance != schema["const"]:
            raise ContractError(f"{location}: expected constant {schema['const']!r}")
        if "enum" in schema and instance not in schema["enum"]:
            raise ContractError(f"{location}: {instance!r} is outside the enum")

        if "oneOf" in schema:
            matches = 0
            for option in schema["oneOf"]:
                try:
                    self.validate(instance, option, document_path, location)
                    matches += 1
                except ContractError:
                    pass
            if matches != 1:
                raise ContractError(f"{location}: expected exactly one matching schema, found {matches}")

        for condition in schema.get("allOf", []):
            self.validate(instance, condition, document_path, location)

        if "if" in schema:
            try:
                self.validate(instance, schema["if"], document_path, location)
            except ContractError:
                branch = schema.get("else")
            else:
                branch = schema.get("then")
            if branch is not None:
                self.validate(instance, branch, document_path, location)

        expected_types = schema.get("type")
        if expected_types is not None:
            if isinstance(expected_types, str):
                expected_types = [expected_types]
            if not any(self._has_type(instance, expected) for expected in expected_types):
                raise ContractError(f"{location}: expected type {expected_types}, got {type(instance).__name__}")

        if isinstance(instance, dict):
            required = schema.get("required", [])
            missing = [key for key in required if key not in instance]
            if missing:
                raise ContractError(f"{location}: missing required properties {missing}")
            properties = schema.get("properties", {})
            for key, child in instance.items():
                if key in properties:
                    self.validate(child, properties[key], document_path, f"{location}.{key}")
                elif schema.get("additionalProperties") is False:
                    raise ContractError(f"{location}: unexpected property {key!r}")
                elif isinstance(schema.get("additionalProperties"), dict):
                    self.validate(
                        child,
                        schema["additionalProperties"],
                        document_path,
                        f"{location}.{key}",
                    )
            property_names = schema.get("propertyNames")
            if property_names:
                for key in instance:
                    self.validate(key, property_names, document_path, f"{location}.<property>")
            if len(instance) < schema.get("minProperties", 0):
                raise ContractError(f"{location}: too few properties")
            if "maxProperties" in schema and len(instance) > schema["maxProperties"]:
                raise ContractError(f"{location}: too many properties")

        if isinstance(instance, list):
            if len(instance) < schema.get("minItems", 0):
                raise ContractError(f"{location}: too few items")
            if "maxItems" in schema and len(instance) > schema["maxItems"]:
                raise ContractError(f"{location}: too many items")
            if schema.get("uniqueItems"):
                encoded = [
                    json.dumps(item, sort_keys=True, separators=(",", ":"), default=str)
                    for item in instance
                ]
                if len(encoded) != len(set(encoded)):
                    raise ContractError(f"{location}: items must be unique")
            if "items" in schema:
                for index, child in enumerate(instance):
                    self.validate(child, schema["items"], document_path, f"{location}[{index}]")

        if isinstance(instance, str):
            if len(instance) < schema.get("minLength", 0):
                raise ContractError(f"{location}: string is too short")
            if "maxLength" in schema and len(instance) > schema["maxLength"]:
                raise ContractError(f"{location}: string is too long")
            if "pattern" in schema and re.fullmatch(schema["pattern"], instance) is None:
                raise ContractError(f"{location}: string does not match {schema['pattern']!r}")
            self._validate_format(instance, schema.get("format"), location)

        if self._is_number(instance):
            if "minimum" in schema and instance < schema["minimum"]:
                raise ContractError(f"{location}: number is below minimum")
            if "maximum" in schema and instance > schema["maximum"]:
                raise ContractError(f"{location}: number is above maximum")
            if "multipleOf" in schema:
                try:
                    if Decimal(str(instance)) % Decimal(str(schema["multipleOf"])) != 0:
                        raise ContractError(f"{location}: number is not an exact multiple")
                except InvalidOperation as error:
                    raise ContractError(f"{location}: invalid decimal") from error

    @staticmethod
    def _has_type(instance: Any, expected: str) -> bool:
        return {
            "null": instance is None,
            "object": isinstance(instance, dict),
            "array": isinstance(instance, list),
            "string": isinstance(instance, str),
            "boolean": isinstance(instance, bool),
            "integer": isinstance(instance, int) and not isinstance(instance, bool),
            "number": isinstance(instance, (int, float, Decimal)) and not isinstance(instance, bool),
        }.get(expected, False)

    @staticmethod
    def _is_number(instance: Any) -> bool:
        return isinstance(instance, (int, float, Decimal)) and not isinstance(instance, bool)

    @staticmethod
    def _validate_format(value: str, format_name: str | None, location: str) -> None:
        try:
            if format_name == "uuid":
                uuid.UUID(value)
            elif format_name == "date-time":
                if re.fullmatch(
                    r"[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])"
                    r"T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]"
                    r"(?:\.[0-9]{1,6})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])",
                    value,
                ) is None:
                    raise ValueError("canonical RFC 3339 timestamp required")
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError("timezone required")
            elif format_name == "date":
                if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value) is None:
                    raise ValueError("canonical full-date required")
                if date.fromisoformat(value).isoformat() != value:
                    raise ValueError("date does not round-trip")
        except ValueError as error:
            raise ContractError(f"{location}: invalid {format_name}") from error


def expect_rejected(
    validator: SchemaValidator,
    instance: Any,
    schema: dict[str, Any],
    schema_path: Path,
    label: str,
) -> None:
    try:
        validator.validate(instance, schema, schema_path)
    except ContractError:
        return
    raise ContractError(f"negative fixture was accepted: {label}")


def expect_semantic_rejected(callback: Any, label: str) -> None:
    try:
        callback()
    except ContractError:
        return
    raise ContractError(f"negative semantic fixture was accepted: {label}")


def validate_display_name(value: str | None, *, require_canonical: bool) -> None:
    if value is None:
        return
    normalized = unicodedata.normalize("NFC", value)
    forbidden_values = {
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    }
    if any(unicodedata.category(char) in {"Cc", "Zl", "Zp"} for char in normalized):
        raise ContractError("display name contains a forbidden general category")
    if any(ord(char) in forbidden_values for char in normalized):
        raise ContractError("display name contains a forbidden formatting scalar")
    whitespace = {
        *range(9, 14), 32, 133, 160, 5760,
        *range(8192, 8204), 8232, 8233, 8239, 8287, 12288,
    }
    first = 0
    last = len(normalized)
    while first < last and ord(normalized[first]) in whitespace:
        first += 1
    while last > first and ord(normalized[last - 1]) in whitespace:
        last -= 1
    clean = normalized[first:last]
    if not clean or len(clean) > 80 or len(clean.encode("utf-8")) > 320:
        raise ContractError("display name is empty or exceeds a shared bound")
    if not any(unicodedata.category(char)[0] in {"L", "N"}
               or unicodedata.category(char) in {"Sm", "Sc", "Sk", "So"}
               for char in clean):
        raise ContractError("display name has no visible letter, number, or symbol")
    if require_canonical and value.encode("utf-8") != clean.encode("utf-8"):
        raise ContractError("server display name is not canonical NFC/trimmed UTF-8")


def canonical_asset_path(workspace_id: str, asset_id: str) -> str:
    return f"workspaces/{uuid.UUID(workspace_id)}/vision-images/{uuid.UUID(asset_id)}.jpg"


def validate_push_semantics(request: dict[str, Any]) -> None:
    workspace_id = request["p_workspace_id"]
    operation_ids: set[str] = set()
    required_create_fields = {
        "workspace": set(),
        "move": {"title", "details", "status", "priority", "source", "createdAt"},
        "appearance": {"schemaVersion", "preferences"},
        "primaryGoal": {"title", "metric", "unit", "dueOn"},
        "milestone": {"title", "dueAt", "createdAt"},
        "asset": {"kind", "storagePath", "contentType", "byteSize", "sha256"},
    }
    for operation in request["p_operations"]:
        operation_id = operation["operationId"]
        if operation_id in operation_ids:
            raise ContractError("push batch reuses an operation ID")
        operation_ids.add(operation_id)
        fields = set(operation["changedFields"])
        if fields != set(operation["fieldClocks"]):
            raise ContractError("changedFields and fieldClocks differ")
        if operation["action"] == "upsert":
            payload = operation.get("payload")
            if not isinstance(payload, dict) or fields != set(payload):
                raise ContractError("changedFields and payload differ")
            if operation["baseRevision"] == 0 and not required_create_fields[operation["entityType"]] <= fields:
                raise ContractError("new record omits required fields")
            if operation["baseRevision"] > 0 and "createdAt" in fields:
                raise ContractError("createdAt is not immutable")
            if operation["entityType"] == "asset" and "storagePath" in fields:
                expected = canonical_asset_path(workspace_id, operation["entityId"])
                if payload["storagePath"] != expected:
                    raise ContractError("asset path is outside its workspace/entity prefix")
        elif fields != {"deletedAt"} or operation.get("payload") is not None:
            raise ContractError("delete operation has a noncanonical shape")


def validate_bootstrap_semantics(response: dict[str, Any]) -> None:
    if response["session"]["accountId"] != response["profile"]["accountId"]:
        raise ContractError("bootstrap profile account differs from session")
    if response["session"]["identityProvider"] != response["profile"]["identityProvider"]:
        raise ContractError("bootstrap identity provider differs from session")
    if response["session"]["workspaceId"] != response["workspace"]["id"]:
        raise ContractError("bootstrap workspace differs from session")
    if response["startingCursor"] != 0 or response["latestCursor"] < response["startingCursor"]:
        raise ContractError("bootstrap cursor relationship is invalid")
    validate_display_name(response["profile"].get("displayName"), require_canonical=True)


def validate_record_clock_claim(record: dict[str, Any], fields: list[str], label: str) -> None:
    clocks = record.get("fieldClocks")
    if not isinstance(clocks, dict) or not set(fields) <= set(clocks):
        raise ContractError(f"{label} record omits a clock for a claimed field")


def validate_push_response_semantics(response: dict[str, Any]) -> None:
    workspace_id = response["workspaceId"]
    for result in response["results"]:
        conflict = result.get("conflict")
        if not isinstance(conflict, dict):
            continue
        record = conflict.get("serverRecord")
        if record is None:
            continue
        if record.get("id") != conflict["entityId"]:
            raise ContractError("conflict record does not match entity ID")
        if record.get("revision") != conflict["currentRevision"]:
            raise ContractError("conflict record does not match current revision")
        validate_record_clock_claim(record, conflict["conflictingFields"], "conflict")
        if conflict["entityType"] == "asset":
            expected = canonical_asset_path(workspace_id, conflict["entityId"])
            if record.get("storagePath") != expected:
                raise ContractError("conflict asset path crosses its response workspace")


def validate_pull_semantics(response: dict[str, Any]) -> None:
    start = response["fromCursor"]
    next_cursor = response["nextCursor"]
    latest = response["latestCursor"]
    changes = response["changes"]
    cursors = [change["cursor"] for change in changes]
    if not (start <= next_cursor <= latest):
        raise ContractError("pull cursor bounds are invalid")
    if any(left >= right for left, right in zip(cursors, cursors[1:])):
        raise ContractError("pull cursors are not strictly ascending")
    if any(cursor <= start or cursor > next_cursor for cursor in cursors):
        raise ContractError("pull change lies outside the page")
    if (cursors[-1] if cursors else start) != next_cursor:
        raise ContractError("pull page does not account for nextCursor")
    if response["hasMore"]:
        if not changes or not next_cursor < latest:
            raise ContractError("hasMore page cannot make forward progress")
    elif next_cursor != latest:
        raise ContractError("final pull page does not reach latestCursor")
    for change in changes:
        record = change["record"]
        if not isinstance(record, dict) or record.get("id") != change["entityId"]:
            raise ContractError("change record does not match entity ID")
        if record.get("revision") != change["revision"]:
            raise ContractError("change record does not match revision")
        validate_record_clock_claim(record, change["changedFields"], "change")
        if change["entityType"] == "asset":
            expected = canonical_asset_path(response["workspaceId"], change["entityId"])
            if record.get("storagePath") != expected:
                raise ContractError("change asset path crosses its response workspace")
        if change["action"] == "delete":
            if change["changedFields"] != ["deletedAt"] or not isinstance(record.get("deletedAt"), str):
                raise ContractError("delete change lacks its tombstone")


def validate_export_semantics(response: dict[str, Any]) -> None:
    workspace_id = response["workspace"]["id"]
    manifest = response["assetTransfer"]["manifest"]
    assets = response["assets"]
    if len(assets) != len(manifest):
        raise ContractError("asset record and manifest counts differ")
    manifest_by_id = {item["id"]: item for item in manifest}
    if len(manifest_by_id) != len(manifest):
        raise ContractError("asset manifest has duplicate IDs")
    comparable_fields = {"id", "storagePath", "contentType", "byteSize", "sha256", "deletedAt"}
    for asset in assets:
        expected_path = canonical_asset_path(workspace_id, asset["id"])
        if asset["storagePath"] != expected_path:
            raise ContractError("asset record has a cross-workspace or noncanonical path")
        item = manifest_by_id.get(asset["id"])
        if item is None or {key: asset.get(key) for key in comparable_fields} != item:
            raise ContractError("asset manifest does not exactly match its record")
    if (response["assetTransfer"]["state"] == "notRequired") != (not manifest):
        raise ContractError("asset transfer state does not match manifest emptiness")


def validate_contracts() -> None:
    validator = SchemaValidator()
    records_path = SCHEMA_ROOT / "records.schema.json"
    sync_path = SCHEMA_ROOT / "sync.schema.json"
    openapi_path = CONTRACT_ROOT / "openapi.json"
    records = validator.document(records_path)
    sync = validator.document(sync_path)
    openapi = validator.document(openapi_path)

    for document, path in ((records, records_path), (sync, sync_path), (openapi, openapi_path)):
        validator.check_references(document, path)

    expected_paths = {
        "/rest/v1/rpc/bootstrap_workspace": "bootstrapWorkspace",
        "/rest/v1/rpc/push_operations": "pushOperations",
        "/rest/v1/rpc/pull_changes": "pullChanges",
        "/rest/v1/rpc/export_workspace": "exportWorkspace",
        "/rest/v1/rpc/erase_workspace": "eraseWorkspace",
    }
    if set(openapi.get("paths", {})) != set(expected_paths):
        raise ContractError("OpenAPI paths do not match the five canonical v1 RPCs")
    for path, operation_id in expected_paths.items():
        if openapi["paths"][path].get("post", {}).get("operationId") != operation_id:
            raise ContractError(f"OpenAPI operationId mismatch for {path}")

    push_fixture = load_json(CONTRACT_ROOT / "fixtures" / "push-operations.request.json")
    milestone_push_fixture = load_json(CONTRACT_ROOT / "fixtures" / "milestone-upsert.request.json")
    bootstrap_fixture = load_json(CONTRACT_ROOT / "fixtures" / "bootstrap.response.json")
    activity_fixture = load_json(CONTRACT_ROOT / "fixtures" / "activity-event.json")
    push_response_fixture = load_json(CONTRACT_ROOT / "fixtures" / "push.response.json")
    pull_response_fixture = load_json(CONTRACT_ROOT / "fixtures" / "pull.response.json")
    export_fixture = load_json(CONTRACT_ROOT / "fixtures" / "export.response.json")
    export_asset_fixture = load_json(CONTRACT_ROOT / "fixtures" / "export-with-asset.response.json")
    erase_fixture = load_json(CONTRACT_ROOT / "fixtures" / "erase.response.json")
    validator.validate(push_fixture, sync["$defs"]["PushRequest"], sync_path)
    validator.validate(milestone_push_fixture, sync["$defs"]["PushRequest"], sync_path)
    validator.validate(bootstrap_fixture, sync["$defs"]["BootstrapResponse"], sync_path)
    validator.validate(activity_fixture, sync["$defs"]["ActivityEvent"], sync_path)
    validator.validate(push_response_fixture, sync["$defs"]["PushResponse"], sync_path)
    validator.validate(pull_response_fixture, sync["$defs"]["PullResponse"], sync_path)
    validator.validate(export_fixture, sync["$defs"]["ExportResponse"], sync_path)
    validator.validate(export_asset_fixture, sync["$defs"]["ExportResponse"], sync_path)
    validator.validate(erase_fixture, sync["$defs"]["EraseResponse"], sync_path)
    validate_push_semantics(push_fixture)
    validate_push_semantics(milestone_push_fixture)
    validate_bootstrap_semantics(bootstrap_fixture)
    validate_push_response_semantics(push_response_fixture)
    validate_pull_semantics(pull_response_fixture)
    validate_export_semantics(export_fixture)
    validate_export_semantics(export_asset_fixture)

    if push_response_fixture["latestCursor"] != 9_007_199_254_740_993:
        raise ContractError("fixture parser lost a 64-bit integer above 2^53")

    duplicate_mask = copy.deepcopy(push_fixture)
    duplicate_mask["p_operations"][0]["changedFields"].append("title")
    expect_rejected(validator, duplicate_mask, sync["$defs"]["PushRequest"], sync_path, "duplicate field mask")

    bad_provider = copy.deepcopy(bootstrap_fixture)
    bad_provider["session"]["identityProvider"] = "connector"
    expect_rejected(validator, bad_provider, sync["$defs"]["BootstrapResponse"], sync_path, "connector as product identity")

    long_display_name = copy.deepcopy(bootstrap_fixture)
    long_display_name["profile"]["displayName"] = "x" * 81
    expect_rejected(
        validator,
        long_display_name,
        sync["$defs"]["BootstrapResponse"],
        sync_path,
        "overlong display name",
    )

    malformed_time = copy.deepcopy(activity_fixture)
    malformed_time["occurredAt"] = "tomorrow"
    expect_rejected(validator, malformed_time, sync["$defs"]["ActivityEvent"], sync_path, "malformed timestamp")

    postgres_timestamp_alias = copy.deepcopy(activity_fixture)
    postgres_timestamp_alias["occurredAt"] = "2026-08-31 10:00:00+00"
    expect_rejected(
        validator,
        postgres_timestamp_alias,
        sync["$defs"]["ActivityEvent"],
        sync_path,
        "noncanonical PostgreSQL timestamp alias",
    )

    extra_property = copy.deepcopy(bootstrap_fixture)
    extra_property["profile"]["email"] = "must-not-be-a-tenancy-key@example.invalid"
    expect_rejected(validator, extra_property, sync["$defs"]["BootstrapResponse"], sync_path, "profile email")

    content_metadata = copy.deepcopy(activity_fixture)
    content_metadata["metadata"] = {"title": "must not leave the workspace"}
    expect_rejected(
        validator,
        content_metadata,
        sync["$defs"]["ActivityEvent"],
        sync_path,
        "content-bearing activity metadata",
    )

    wrong_entity_field = copy.deepcopy(push_fixture)
    operation = wrong_entity_field["p_operations"][0]
    operation["entityType"] = "workspace"
    operation["entityId"] = wrong_entity_field["p_workspace_id"]
    operation["changedFields"] = ["priority"]
    operation["fieldClocks"] = {"priority": "2026-08-31T10:00:00Z"}
    operation["payload"] = {"priority": "P0"}
    expect_rejected(
        validator,
        wrong_entity_field,
        sync["$defs"]["PushRequest"],
        sync_path,
        "field from another entity",
    )

    malformed_result = copy.deepcopy(push_response_fixture)
    del malformed_result["results"][0]["cursor"]
    expect_rejected(
        validator,
        malformed_result,
        sync["$defs"]["PushResponse"],
        sync_path,
        "accepted result without cursor",
    )

    missing_asset_transfer = copy.deepcopy(export_fixture)
    del missing_asset_transfer["assetTransfer"]
    expect_rejected(
        validator,
        missing_asset_transfer,
        sync["$defs"]["ExportResponse"],
        sync_path,
        "export without private-object transfer status",
    )

    missing_milestones = copy.deepcopy(export_fixture)
    del missing_milestones["milestones"]
    expect_rejected(
        validator,
        missing_milestones,
        sync["$defs"]["ExportResponse"],
        sync_path,
        "export without milestone history",
    )

    stale_final_page = copy.deepcopy(pull_response_fixture)
    stale_final_page["latestCursor"] += 1
    expect_semantic_rejected(
        lambda: validate_pull_semantics(stale_final_page),
        "hasMore false before latestCursor",
    )

    empty_continuation = copy.deepcopy(pull_response_fixture)
    empty_continuation["fromCursor"] = empty_continuation["nextCursor"]
    empty_continuation["latestCursor"] += 1
    empty_continuation["hasMore"] = True
    empty_continuation["changes"] = []
    expect_semantic_rejected(
        lambda: validate_pull_semantics(empty_continuation),
        "empty non-advancing hasMore page",
    )

    wrong_change_record = copy.deepcopy(pull_response_fixture)
    wrong_change_record["changes"][0]["record"]["id"] = "99999999-9999-4999-8999-999999999999"
    expect_semantic_rejected(
        lambda: validate_pull_semantics(wrong_change_record),
        "change with a different record ID",
    )

    missing_change_clock = copy.deepcopy(pull_response_fixture)
    changed_field = missing_change_clock["changes"][0]["changedFields"][0]
    missing_change_clock["changes"][0]["record"]["fieldClocks"].pop(changed_field)
    expect_semantic_rejected(
        lambda: validate_pull_semantics(missing_change_clock),
        "change record without a clock for its claimed field",
    )

    wrong_bootstrap_workspace = copy.deepcopy(bootstrap_fixture)
    wrong_bootstrap_workspace["session"]["workspaceId"] = "99999999-9999-4999-8999-999999999999"
    expect_semantic_rejected(
        lambda: validate_bootstrap_semantics(wrong_bootstrap_workspace),
        "bootstrap session/workspace mismatch",
    )

    noncanonical_server_name = copy.deepcopy(bootstrap_fixture)
    noncanonical_server_name["profile"]["displayName"] = " e\u0301 "
    expect_semantic_rejected(
        lambda: validate_bootstrap_semantics(noncanonical_server_name),
        "noncanonical server display name",
    )

    cross_workspace_asset = copy.deepcopy(export_asset_fixture)
    attacker_workspace = "99999999-9999-4999-8999-999999999999"
    attacker_path = canonical_asset_path(attacker_workspace, cross_workspace_asset["assets"][0]["id"])
    cross_workspace_asset["assets"][0]["storagePath"] = attacker_path
    cross_workspace_asset["assetTransfer"]["manifest"][0]["storagePath"] = attacker_path
    expect_semantic_rejected(
        lambda: validate_export_semantics(cross_workspace_asset),
        "cross-workspace private asset path",
    )

    mismatched_asset_manifest = copy.deepcopy(export_asset_fixture)
    mismatched_asset_manifest["assetTransfer"]["manifest"][0]["sha256"] = "1" * 64
    expect_semantic_rejected(
        lambda: validate_export_semantics(mismatched_asset_manifest),
        "asset manifest with different content digest",
    )

    asset = copy.deepcopy(export_asset_fixture["assets"][0])
    asset["storagePath"] = canonical_asset_path(attacker_workspace, asset["id"])
    cross_workspace_conflict = {
        "contractVersion": 1,
        "workspaceId": export_asset_fixture["workspace"]["id"],
        "latestCursor": 1,
        "results": [{
            "operationId": "40000000-0000-4000-8000-000000000004",
            "status": "conflict",
            "conflict": {
                "operationId": "40000000-0000-4000-8000-000000000004",
                "entityType": "asset",
                "entityId": asset["id"],
                "baseRevision": 0,
                "currentRevision": asset["revision"],
                "reason": "overlappingChanges",
                "conflictingFields": ["storagePath"],
                "serverRecord": asset,
            },
        }],
    }
    validator.validate(cross_workspace_conflict, sync["$defs"]["PushResponse"], sync_path)
    expect_semantic_rejected(
        lambda: validate_push_response_semantics(cross_workspace_conflict),
        "cross-workspace asset in a conflict response",
    )

    missing_conflict_clock = copy.deepcopy(cross_workspace_conflict)
    missing_conflict_clock["workspaceId"] = attacker_workspace
    missing_conflict_clock["results"][0]["conflict"]["serverRecord"]["fieldClocks"].pop(
        "storagePath"
    )
    expect_semantic_rejected(
        lambda: validate_push_response_semantics(missing_conflict_clock),
        "conflict record without a clock for its claimed field",
    )

    required_error_responses = {
        "/rest/v1/rpc/bootstrap_workspace": {"400", "401", "403", "409"},
        "/rest/v1/rpc/push_operations": {"400", "401", "403", "503"},
        "/rest/v1/rpc/pull_changes": {"400", "401", "403"},
        "/rest/v1/rpc/export_workspace": {"401", "403"},
        "/rest/v1/rpc/erase_workspace": {"400", "401", "403", "409", "503"},
    }
    for path, expected_errors in required_error_responses.items():
        actual = set(openapi["paths"][path]["post"]["responses"])
        missing = expected_errors - actual
        if missing:
            raise ContractError(f"OpenAPI {path} is missing error responses {sorted(missing)}")


def validate_migrations() -> None:
    table_sql = (MIGRATION_ROOT / "20260831130000_sync_tables_and_rls.sql").read_text(encoding="utf-8")
    rpc_sql = (MIGRATION_ROOT / "20260831130100_sync_rpc_boundaries.sql").read_text(encoding="utf-8")
    combined = table_sql + "\n" + rpc_sql

    required_tables = {
        "profiles",
        "workspaces",
        "workspace_members",
        "moves",
        "appearance",
        "primary_goals",
        "milestones",
        "assets",
        "change_log",
        "device_cursors",
        "activity_events",
    }
    for table in required_tables:
        if f"create table public.{table}" not in table_sql:
            raise ContractError(f"migration does not create public.{table}")
        if f"alter table public.{table} force row level security" not in table_sql:
            raise ContractError(f"migration does not force RLS on public.{table}")

    private_tables = {
        "sync_operation_receipts",
        "workspace_erasure_receipts",
        "product_capabilities",
        "workspace_asset_transfers",
    }
    for table in private_tables:
        if f"create table private.{table}" not in table_sql:
            raise ContractError(f"migration does not create private.{table}")

    canonical_functions = {
        "bootstrap_workspace",
        "push_operations",
        "pull_changes",
        "export_workspace",
        "erase_workspace",
    }
    for function in canonical_functions:
        if f"create or replace function public.{function}" not in rpc_sql:
            raise ContractError(f"migration does not create public.{function}")
        if not re.search(rf"grant execute on function public\.{function}\([^;]+\) to authenticated;", rpc_sql):
            raise ContractError(f"authenticated role lacks the explicit {function} grant")
    if re.search(r"create\s+(?:or\s+replace\s+)?function\s+public\.sync_", rpc_sql, re.IGNORECASE):
        raise ContractError("legacy public sync_* RPC is present")

    required_merge_tokens = (
        "changed_fields text[] not null",
        "field_clocks jsonb not null",
        "field_writers jsonb not null",
        "newer_change.changed_fields && changed_field_names",
        "'overlappingChanges'",
        "'conflictingFields', conflicting_fields",
        "interval '5 minutes'",
        "operation ID was reused with different content",
        "operation IDs must be unique within a push batch",
        "sync_operation_receipts",
        "workspace_erasure_receipts",
        "workspaces_one_per_owner_v1",
        "activity_events_metadata_empty_v1",
        "'startingCursor', 0",
        "pull cursor is ahead of the workspace feed",
        "numeric(30, 8)",
        "errcode = 'PT503'",
        "deletion_verified_at is not null",
        "is_valid_display_name_v1",
        "octet_length(clean_candidate) > 320",
        "codepoint between 8234 and 8238",
        "private.is_canonical_date_v1",
        "private.is_canonical_timestamp_v1",
        "workspaces/' || workspace_id::text || '/vision-images/' || id::text || '.jpg",
        "content_type = 'image/jpeg'",
        "byte_size between 1 and 5242880",
        "when 'milestone' then",
        "'milestones', coalesce((",
        "founder_office_guard_auth_user_delete_v1",
        "erase the product workspace before deleting the Auth identity",
        "set owner_account_id = null",
    )
    for token in required_merge_tokens:
        if token not in combined:
            raise ContractError(f"migration is missing merge safety token {token!r}")

    if re.search(r"grant\s+(?:all|insert|update|delete)", combined, re.IGNORECASE):
        raise ContractError("migration grants direct mutation privileges")
    if "service_role" in combined:
        raise ContractError("migration embeds or grants a service role")
    if "revoke all on all tables in schema public" in combined:
        raise ContractError("migration changes privileges on unrelated public tables")

    for sql, name in ((table_sql, "tables/RLS"), (rpc_sql, "RPC")):
        if not sql.lstrip().lower().startswith("begin;") or not sql.rstrip().lower().endswith("commit;"):
            raise ContractError(f"{name} migration is not transaction-wrapped")
        if sql.count("$$") % 2:
            raise ContractError(f"{name} migration has an unbalanced dollar quote")

    security_definers = re.finditer(
        r"create or replace function\s+([^\s(]+).*?security definer(.*?)(?=\$\$;)",
        combined,
        re.IGNORECASE | re.DOTALL,
    )
    for match in security_definers:
        if "set search_path = ''" not in match.group(0).lower():
            raise ContractError(f"security-definer {match.group(1)} lacks an empty search_path")

    swift_contract = SWIFT_CONTRACT_PATH.read_text(encoding="utf-8")
    if "public enum ProductIdentityProvider" in swift_contract:
        raise ContractError("core sync contract collides with FounderOfficeIdentity.ProductIdentityProvider")
    if re.search(r"^\s*public var ", swift_contract, re.MULTILINE):
        raise ContractError("validated public sync contract fields must be immutable")
    for token in (
        "public enum AccountIdentityProvider",
        "maximumUnicodeScalarCount = 80",
        "maximumUTF8ByteCount = 320",
        ".precomposedStringWithCanonicalMapping",
        ".control, .lineSeparator, .paragraphSeparator",
        ".mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol",
        "case number(Decimal)",
        "case milestone",
        "!changes.isEmpty && nextCursor < latestCursor",
        "validateAssetCorrespondence",
        "requiredClockFields: Set<String>",
    ):
        if token not in swift_contract:
            raise ContractError(f"Swift contract is missing alignment token {token!r}")


def validate_pgtap_contract() -> None:
    sql = PGTAP_PATH.read_text(encoding="utf-8")
    plan_match = re.search(r"select\s+plan\((\d+)\);", sql, re.IGNORECASE)
    if not plan_match:
        raise ContractError("pgTAP suite has no plan")
    assertion_pattern = re.compile(
        r"^select\s+(?:has_|hasnt_|col_|ok\(|is\(|throws_ok\()",
        re.IGNORECASE | re.MULTILINE,
    )
    assertion_count = len(assertion_pattern.findall(sql))
    if int(plan_match.group(1)) != assertion_count:
        raise ContractError(
            f"pgTAP plan declares {plan_match.group(1)} but suite contains {assertion_count} assertions"
        )

    required_coverage = (
        "set local role anon",
        "set local role authenticated",
        "unrelated user",
        "operation IDs make retries idempotent",
        "stale disjoint field edit merges",
        "stale same-field edit conflicts",
        "operation clock is too far in the future",
        "deleted account",
        "different content",
        "one workspace per owner",
        "cursor ahead",
        "erasure retry is idempotent",
        "erased workspace cannot be resurrected",
        "direct-write matrix",
        "RLS read matrix",
        "RPC execute matrix",
        "SECURITY DEFINER ownership matrix",
        "display-name boundary",
        "milestone is a first-class sync entity",
        "date-only Move deadlines",
        "cross-workspace private object reference",
        "account deletion cannot bypass workspace asset export and erasure gates",
        "non-resurrection tombstone",
    )
    for token in required_coverage:
        if token.lower() not in sql.lower():
            raise ContractError(f"pgTAP suite is missing coverage marker {token!r}")


def main() -> int:
    try:
        validate_contracts()
        validate_migrations()
        validate_pgtap_contract()
    except ContractError as error:
        print(f"Sync contract validation failed: {error}", file=sys.stderr)
        return 1
    print("Sync contracts, fixtures, migration safety, and pgTAP coverage passed static validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
