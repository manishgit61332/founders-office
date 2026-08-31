#!/usr/bin/env python3
"""Validate the credential-free v1 sync contracts without third-party packages."""

from __future__ import annotations

import copy
import json
import re
import sys
import uuid
from datetime import date, datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_ROOT = ROOT / "contracts" / "v1"
SCHEMA_ROOT = CONTRACT_ROOT / "schemas"
MIGRATION_ROOT = ROOT / "supabase" / "migrations"
PGTAP_PATH = ROOT / "supabase" / "tests" / "001_sync_rls_and_rpc.test.sql"


class ContractError(Exception):
    pass


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
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
                encoded = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in instance]
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

    @staticmethod
    def _has_type(instance: Any, expected: str) -> bool:
        return {
            "null": instance is None,
            "object": isinstance(instance, dict),
            "array": isinstance(instance, list),
            "string": isinstance(instance, str),
            "boolean": isinstance(instance, bool),
            "integer": isinstance(instance, int) and not isinstance(instance, bool),
            "number": isinstance(instance, (int, float)) and not isinstance(instance, bool),
        }.get(expected, False)

    @staticmethod
    def _is_number(instance: Any) -> bool:
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)

    @staticmethod
    def _validate_format(value: str, format_name: str | None, location: str) -> None:
        try:
            if format_name == "uuid":
                uuid.UUID(value)
            elif format_name == "date-time":
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError("timezone required")
            elif format_name == "date":
                date.fromisoformat(value)
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
    bootstrap_fixture = load_json(CONTRACT_ROOT / "fixtures" / "bootstrap.response.json")
    activity_fixture = load_json(CONTRACT_ROOT / "fixtures" / "activity-event.json")
    validator.validate(push_fixture, sync["$defs"]["PushRequest"], sync_path)
    validator.validate(bootstrap_fixture, sync["$defs"]["BootstrapResponse"], sync_path)
    validator.validate(activity_fixture, sync["$defs"]["ActivityEvent"], sync_path)

    if activity_fixture["metadata"]["revision"] != 9_007_199_254_740_993:
        raise ContractError("fixture parser lost a 64-bit integer above 2^53")

    duplicate_mask = copy.deepcopy(push_fixture)
    duplicate_mask["p_operations"][0]["changedFields"].append("title")
    expect_rejected(validator, duplicate_mask, sync["$defs"]["PushRequest"], sync_path, "duplicate field mask")

    bad_provider = copy.deepcopy(bootstrap_fixture)
    bad_provider["session"]["identityProvider"] = "connector"
    expect_rejected(validator, bad_provider, sync["$defs"]["BootstrapResponse"], sync_path, "connector as product identity")

    long_display_name = copy.deepcopy(bootstrap_fixture)
    long_display_name["profile"]["displayName"] = "x" * 121
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

    extra_property = copy.deepcopy(bootstrap_fixture)
    extra_property["profile"]["email"] = "must-not-be-a-tenancy-key@example.invalid"
    expect_rejected(validator, extra_property, sync["$defs"]["BootstrapResponse"], sync_path, "profile email")


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
        "interval '5 minutes'",
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


def validate_pgtap_contract() -> None:
    sql = PGTAP_PATH.read_text(encoding="utf-8")
    plan_match = re.search(r"select\s+plan\((\d+)\);", sql, re.IGNORECASE)
    if not plan_match:
        raise ContractError("pgTAP suite has no plan")
    assertion_pattern = re.compile(
        r"^select\s+(?:has_|col_|ok\(|is\(|throws_ok\()",
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
