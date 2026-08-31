begin;

create or replace function private.require_workspace_owner(target_workspace_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    account_id uuid := auth.uid();
begin
    if account_id is null then
        raise exception using errcode = '28000', message = 'authentication required';
    end if;

    if not exists (
        select 1
        from public.workspace_members as membership
        where membership.workspace_id = target_workspace_id
          and membership.account_id = account_id
          and membership.role = 'owner'
    ) then
        raise exception using errcode = '42501', message = 'workspace access denied';
    end if;

    return account_id;
end;
$$;

create or replace function private.is_canonical_date_v1(candidate text)
returns boolean
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
    parsed date;
begin
    if candidate !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        return false;
    end if;

    begin
        parsed := candidate::date;
    exception
        when invalid_datetime_format or datetime_field_overflow then
            return false;
    end;

    return isfinite(parsed) and to_char(parsed, 'YYYY-MM-DD') = candidate;
end;
$$;

create or replace function private.is_canonical_timestamp_v1(candidate text)
returns boolean
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
    parsed timestamptz;
begin
    if candidate !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$' then
        return false;
    end if;

    begin
        parsed := candidate::timestamptz;
    exception
        when invalid_datetime_format or datetime_field_overflow then
            return false;
    end;

    return isfinite(parsed);
end;
$$;

create or replace function private.entity_record(
    target_workspace_id uuid,
    target_entity_type text,
    target_entity_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    result jsonb;
begin
    case target_entity_type
    when 'workspace' then
        select jsonb_build_object(
            'id', workspace.id,
            'name', workspace.name,
            'revision', workspace.revision,
            'fieldClocks', workspace.field_clocks,
            'createdAt', workspace.created_at,
            'updatedAt', workspace.updated_at
        )
        into result
        from public.workspaces as workspace
        where workspace.id = target_workspace_id
          and workspace.id = target_entity_id;

    when 'move' then
        select jsonb_build_object(
            'id', move.id,
            'title', move.title,
            'details', move.details,
            'status', move.status,
            'previousStatus', move.previous_status,
            'priority', move.priority,
            'dueOn', move.due_on,
            'completedAt', move.completed_at,
            'deletedAt', move.deleted_at,
            'source', move.source,
            'revision', move.revision,
            'fieldClocks', move.field_clocks,
            'createdAt', move.created_at,
            'updatedAt', move.updated_at
        )
        into result
        from public.moves as move
        where move.workspace_id = target_workspace_id
          and move.id = target_entity_id;

    when 'appearance' then
        select jsonb_build_object(
            'id', appearance_record.id,
            'schemaVersion', appearance_record.schema_version,
            'preferences', appearance_record.preferences,
            'deletedAt', appearance_record.deleted_at,
            'revision', appearance_record.revision,
            'fieldClocks', appearance_record.field_clocks,
            'createdAt', appearance_record.created_at,
            'updatedAt', appearance_record.updated_at
        )
        into result
        from public.appearance as appearance_record
        where appearance_record.workspace_id = target_workspace_id
          and appearance_record.id = target_entity_id;

    when 'primaryGoal' then
        select jsonb_build_object(
            'id', goal.id,
            'title', goal.title,
            'metric', goal.metric,
            'currentValue', goal.current_value,
            'targetValue', goal.target_value,
            'unit', goal.unit,
            'dueOn', goal.due_on,
            'deletedAt', goal.deleted_at,
            'revision', goal.revision,
            'fieldClocks', goal.field_clocks,
            'createdAt', goal.created_at,
            'updatedAt', goal.updated_at
        )
        into result
        from public.primary_goals as goal
        where goal.workspace_id = target_workspace_id
          and goal.id = target_entity_id;

    when 'milestone' then
        select jsonb_build_object(
            'id', milestone.id,
            'title', milestone.title,
            'dueAt', milestone.due_at,
            'deletedAt', milestone.deleted_at,
            'revision', milestone.revision,
            'fieldClocks', milestone.field_clocks,
            'createdAt', milestone.created_at,
            'updatedAt', milestone.updated_at
        )
        into result
        from public.milestones as milestone
        where milestone.workspace_id = target_workspace_id
          and milestone.id = target_entity_id;

    when 'asset' then
        select jsonb_build_object(
            'id', asset.id,
            'kind', asset.kind,
            'storagePath', asset.storage_path,
            'contentType', asset.content_type,
            'byteSize', asset.byte_size,
            'sha256', asset.sha256,
            'deletedAt', asset.deleted_at,
            'revision', asset.revision,
            'fieldClocks', asset.field_clocks,
            'createdAt', asset.created_at,
            'updatedAt', asset.updated_at
        )
        into result
        from public.assets as asset
        where asset.workspace_id = target_workspace_id
          and asset.id = target_entity_id;

    else
        raise exception using errcode = '22023', message = 'unsupported sync entity type';
    end case;

    return result;
end;
$$;

create or replace function private.entity_field_writers(
    target_workspace_id uuid,
    target_entity_type text,
    target_entity_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    result jsonb := '{}'::jsonb;
begin
    case target_entity_type
    when 'workspace' then
        select workspace.field_writers into result
        from public.workspaces as workspace
        where workspace.id = target_workspace_id and workspace.id = target_entity_id;
    when 'move' then
        select move.field_writers into result
        from public.moves as move
        where move.workspace_id = target_workspace_id and move.id = target_entity_id;
    when 'appearance' then
        select item.field_writers into result
        from public.appearance as item
        where item.workspace_id = target_workspace_id and item.id = target_entity_id;
    when 'primaryGoal' then
        select goal.field_writers into result
        from public.primary_goals as goal
        where goal.workspace_id = target_workspace_id and goal.id = target_entity_id;
    when 'milestone' then
        select milestone.field_writers into result
        from public.milestones as milestone
        where milestone.workspace_id = target_workspace_id and milestone.id = target_entity_id;
    when 'asset' then
        select asset.field_writers into result
        from public.assets as asset
        where asset.workspace_id = target_workspace_id and asset.id = target_entity_id;
    else
        raise exception using errcode = '22023', message = 'unsupported sync entity type';
    end case;

    return coalesce(result, '{}'::jsonb);
end;
$$;

create or replace function private.operation_field_writers(
    changed_fields jsonb,
    operation_id uuid
)
returns jsonb
language sql
stable
set search_path = ''
as $$
    select coalesce(
        jsonb_object_agg(field.value, to_jsonb(operation_id::text)),
        '{}'::jsonb
    )
    from jsonb_array_elements_text(changed_fields) as field(value);
$$;

create or replace function private.incoming_field_clocks_win(
    current_clocks jsonb,
    current_writers jsonb,
    incoming_clocks jsonb,
    changed_fields jsonb,
    operation_id uuid
)
returns boolean
language sql
stable
set search_path = ''
as $$
    select not exists (
        select 1
        from jsonb_array_elements_text(changed_fields) as field(value)
        where current_clocks ? field.value
          and (
              (incoming_clocks ->> field.value)::timestamptz
                  < (current_clocks ->> field.value)::timestamptz
              or (
                  (incoming_clocks ->> field.value)::timestamptz
                      = (current_clocks ->> field.value)::timestamptz
                  and operation_id::text <= coalesce(current_writers ->> field.value, '')
              )
          )
    );
$$;

create or replace function public.bootstrap_workspace(
    p_device_id uuid,
    p_local_workspace_id uuid default null,
    p_workspace_name text default 'Founder''s Office',
    p_display_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    account_id uuid := auth.uid();
    identity_provider text := coalesce(
        auth.jwt() -> 'app_metadata' ->> 'provider',
        auth.jwt() ->> 'provider'
    );
    workspace_id uuid;
    owned_workspace_id uuid;
    erased_owner_id uuid;
    workspace_was_created boolean := false;
    latest_cursor bigint := 0;
    clean_workspace_name text := btrim(p_workspace_name);
    clean_display_name text := case
        when p_display_name is null then null
        else nullif(private.normalize_display_name_v1(p_display_name), '')
    end;
begin
    if account_id is null then
        raise exception using errcode = '28000', message = 'authentication required';
    end if;
    if p_device_id is null then
        raise exception using errcode = '22023', message = 'device ID is required';
    end if;
    if identity_provider not in ('google', 'apple') then
        raise exception using errcode = '28000', message = 'approved identity provider required';
    end if;
    if clean_workspace_name is null or char_length(clean_workspace_name) not between 1 and 120 then
        raise exception using errcode = '22023', message = 'workspace name is invalid';
    end if;
    if p_display_name is not null
       and not private.is_valid_display_name_v1(p_display_name) then
        raise exception using errcode = '22023', message = 'display name is invalid';
    end if;
    if clean_display_name is null
       and not exists (select 1 from public.profiles as profile where profile.id = account_id) then
        raise exception using errcode = '22023', message = 'display name is required for first bootstrap';
    end if;

    insert into public.profiles (id, identity_provider, display_name)
    values (account_id, identity_provider, clean_display_name)
    on conflict (id) do update
    set identity_provider = excluded.identity_provider,
        display_name = coalesce(excluded.display_name, public.profiles.display_name),
        updated_at = now();

    if p_local_workspace_id is not null then
        select receipt.owner_account_id
        into erased_owner_id
        from private.workspace_erasure_receipts as receipt
        where receipt.workspace_id = p_local_workspace_id;

        if found then
            if erased_owner_id = account_id then
                raise exception using errcode = '22023', message = 'workspace was permanently erased';
            else
                raise exception using errcode = '42501', message = 'workspace access denied';
            end if;
        end if;

        select workspace.id
        into workspace_id
        from public.workspaces as workspace
        where workspace.id = p_local_workspace_id
          and workspace.owner_account_id = account_id;

        if workspace_id is null and exists (
            select 1 from public.workspaces as unavailable where unavailable.id = p_local_workspace_id
        ) then
            raise exception using errcode = '42501', message = 'workspace access denied';
        end if;

        if workspace_id is null then
            select workspace.id
            into owned_workspace_id
            from public.workspaces as workspace
            where workspace.owner_account_id = account_id
            order by workspace.created_at, workspace.id
            limit 1;

            if owned_workspace_id is not null then
                raise exception using errcode = '23505', message = 'account already owns a different workspace';
            end if;
        end if;
    else
        select workspace.id
        into workspace_id
        from public.workspaces as workspace
        where workspace.owner_account_id = account_id
        order by workspace.created_at, workspace.id
        limit 1;
    end if;

    if workspace_id is null then
        workspace_id := coalesce(p_local_workspace_id, gen_random_uuid());
        begin
            insert into public.workspaces (
                id,
                owner_account_id,
                name,
                field_clocks,
                field_writers
            ) values (
                workspace_id,
                account_id,
                clean_workspace_name,
                jsonb_build_object('name', now()),
                jsonb_build_object('name', p_device_id)
            );
        exception when unique_violation then
            select workspace.id
            into owned_workspace_id
            from public.workspaces as workspace
            where workspace.owner_account_id = account_id
            order by workspace.created_at, workspace.id
            limit 1;

            if owned_workspace_id is not null
               and (p_local_workspace_id is null or owned_workspace_id = p_local_workspace_id) then
                workspace_id := owned_workspace_id;
            elsif owned_workspace_id is not null then
                raise exception using errcode = '23505', message = 'account already owns a different workspace';
            else
                raise exception using errcode = '42501', message = 'workspace is unavailable';
            end if;
        end;
        workspace_was_created := owned_workspace_id is null;
    end if;

    insert into public.workspace_members (workspace_id, account_id, role)
    values (workspace_id, account_id, 'owner')
    on conflict (workspace_id, account_id) do nothing;

    if workspace_was_created then
        insert into public.activity_events (
            workspace_id,
            actor_account_id,
            device_id,
            kind,
            entity_type,
            entity_id,
            metadata
        ) values (
            workspace_id,
            account_id,
            p_device_id,
            'workspace.created',
            'workspace',
            workspace_id,
            '{}'::jsonb
        );
    end if;

    select coalesce(max(change.cursor), 0)
    into latest_cursor
    from public.change_log as change
    where change.workspace_id = workspace_id;

    insert into public.device_cursors (workspace_id, account_id, device_id, cursor, last_seen_at)
    values (workspace_id, account_id, p_device_id, 0, now())
    on conflict (workspace_id, account_id, device_id) do update
    set last_seen_at = excluded.last_seen_at;

    return jsonb_build_object(
        'contractVersion', 1,
        'session', jsonb_build_object(
            'accountId', account_id,
            'workspaceId', workspace_id,
            'deviceId', p_device_id,
            'identityProvider', identity_provider
        ),
        'profile', (
            select jsonb_build_object(
                'accountId', profile.id,
                'identityProvider', profile.identity_provider,
                'displayName', profile.display_name
            )
            from public.profiles as profile
            where profile.id = account_id
        ),
        'workspace', private.entity_record(workspace_id, 'workspace', workspace_id),
        'startingCursor', 0,
        'latestCursor', latest_cursor
    );
end;
$$;

create or replace function public.push_operations(
    p_workspace_id uuid,
    p_device_id uuid,
    p_operations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    account_id uuid := private.require_workspace_owner(p_workspace_id);
    operation jsonb;
    operation_id uuid;
    entity_type text;
    entity_id uuid;
    action text;
    base_revision bigint;
    changed_fields jsonb;
    field_clocks jsonb;
    changed_field_names text[];
    current_field_clocks jsonb;
    current_field_writers jsonb;
    merged_field_clocks jsonb;
    merged_field_writers jsonb;
    allowed_fields text[];
    required_fields text[];
    field_name text;
    current_revision bigint;
    next_revision bigint;
    occurred_at timestamptz;
    validation_now timestamptz;
    changed_at timestamptz;
    payload jsonb;
    server_record jsonb;
    change_cursor bigint;
    latest_cursor bigint := 0;
    operation_receipt record;
    result_item jsonb;
    results jsonb := '[]'::jsonb;
    seen_operation_ids uuid[] := array[]::uuid[];
    conflicting_fields jsonb := '[]'::jsonb;
begin
    if p_device_id is null then
        raise exception using errcode = '22023', message = 'device ID is required';
    end if;
    if p_operations is null
       or jsonb_typeof(p_operations) <> 'array'
       or jsonb_array_length(p_operations) not between 1 and 100
       or octet_length(p_operations::text) > 2097152 then
        raise exception using errcode = '22023', message = 'operations must contain 1 to 100 items and at most 2 MiB';
    end if;

    for operation in select value from jsonb_array_elements(p_operations)
    loop
        if jsonb_typeof(operation) <> 'object'
           or operation - 'contractVersion' - 'operationId' - 'entityType' - 'entityId'
                        - 'action' - 'baseRevision' - 'changedFields' - 'fieldClocks'
                        - 'payload' - 'occurredAt' <> '{}'::jsonb
           or not operation ?& array[
               'contractVersion', 'operationId', 'entityType', 'entityId', 'action',
               'baseRevision', 'changedFields', 'fieldClocks', 'occurredAt'
           ] then
            raise exception using errcode = '22023', message = 'operation has an invalid shape';
        end if;

        if jsonb_typeof(operation -> 'contractVersion') <> 'number'
           or (operation ->> 'contractVersion') !~ '^(0|[1-9][0-9]*)$'
           or jsonb_typeof(operation -> 'operationId') <> 'string'
           or jsonb_typeof(operation -> 'entityType') <> 'string'
           or jsonb_typeof(operation -> 'entityId') <> 'string'
           or jsonb_typeof(operation -> 'action') <> 'string'
           or jsonb_typeof(operation -> 'baseRevision') <> 'number'
           or (operation ->> 'baseRevision') !~ '^(0|[1-9][0-9]*)$'
           or jsonb_typeof(operation -> 'occurredAt') <> 'string'
           or not private.is_canonical_timestamp_v1(operation ->> 'occurredAt') then
            raise exception using errcode = '22023', message = 'operation scalar types are invalid';
        end if;

        begin
            if (operation ->> 'contractVersion')::integer is distinct from 1 then
                raise exception using errcode = '22023', message = 'unsupported contract version';
            end if;
            operation_id := (operation ->> 'operationId')::uuid;
            entity_type := operation ->> 'entityType';
            entity_id := (operation ->> 'entityId')::uuid;
            action := operation ->> 'action';
            base_revision := (operation ->> 'baseRevision')::bigint;
            changed_fields := operation -> 'changedFields';
            field_clocks := operation -> 'fieldClocks';
            occurred_at := (operation ->> 'occurredAt')::timestamptz;
            payload := operation -> 'payload';
        exception
            when invalid_text_representation or numeric_value_out_of_range or datetime_field_overflow then
            raise exception using errcode = '22023', message = 'operation contains an invalid identifier, revision, or timestamp';
        end;

        if operation_id = any(seen_operation_ids) then
            raise exception using errcode = '22023', message = 'operation IDs must be unique within a push batch';
        end if;
        seen_operation_ids := array_append(seen_operation_ids, operation_id);

        if entity_type is null
           or entity_type not in ('workspace', 'move', 'appearance', 'primaryGoal', 'milestone', 'asset')
           or action is null
           or action not in ('upsert', 'delete')
           or operation_id is null
           or entity_id is null
           or base_revision is null
           or base_revision < 0
           or occurred_at is null
           or not isfinite(occurred_at)
           or jsonb_typeof(operation -> 'occurredAt') <> 'string'
           or jsonb_typeof(changed_fields) <> 'array'
           or jsonb_array_length(changed_fields) not between 1 and 32
           or jsonb_typeof(field_clocks) <> 'object'
           or (select count(*) from jsonb_object_keys(field_clocks)) not between 1 and 32
           or (action = 'upsert' and jsonb_typeof(payload) <> 'object')
           or (action = 'delete' and payload is not null and payload <> 'null'::jsonb) then
            raise exception using errcode = '22023', message = 'operation values are invalid';
        end if;
        if entity_type = 'workspace' and entity_id <> p_workspace_id then
            raise exception using errcode = '22023', message = 'workspace operation entity ID must match the workspace';
        end if;

        if exists (
            select 1
            from jsonb_array_elements(changed_fields) as field(value)
            where jsonb_typeof(field.value) <> 'string'
        ) or exists (
            select field.value
            from jsonb_array_elements_text(changed_fields) as field(value)
            group by field.value
            having count(*) > 1
        ) or exists (
            select 1
            from jsonb_array_elements_text(changed_fields) as field(value)
            where field.value !~ '^[A-Za-z][A-Za-z0-9]{0,63}$'
               or not field_clocks ? field.value
        ) or exists (
            select 1
            from jsonb_object_keys(field_clocks) as clock(field_name)
            where not changed_fields ? clock.field_name
        ) then
            raise exception using errcode = '22023', message = 'changed fields and field clocks must match exactly';
        end if;

        begin
            perform (field_clocks ->> field.value)::timestamptz
            from jsonb_array_elements_text(changed_fields) as field(value);
        exception when invalid_text_representation or datetime_field_overflow then
            raise exception using errcode = '22023', message = 'field clock is invalid';
        end;

        if exists (
            select 1
            from jsonb_array_elements_text(changed_fields) as field(value)
            where jsonb_typeof(field_clocks -> field.value) <> 'string'
               or not private.is_canonical_timestamp_v1(field_clocks ->> field.value)
        ) then
            raise exception using errcode = '22023', message = 'field clock is invalid';
        end if;

        validation_now := clock_timestamp();
        if occurred_at > validation_now + interval '5 minutes'
           or exists (
               select 1
               from jsonb_array_elements_text(changed_fields) as field(value)
               where (field_clocks ->> field.value)::timestamptz
                   > validation_now + interval '5 minutes'
           ) then
            raise exception using errcode = '22023', message = 'operation clock is too far in the future';
        end if;

        select array_agg(field.value order by field.ordinality)
        into changed_field_names
        from jsonb_array_elements_text(changed_fields) with ordinality as field(value, ordinality);

        case entity_type
        when 'workspace' then
            allowed_fields := array['name'];
            required_fields := array[]::text[];
        when 'move' then
            allowed_fields := array[
                'title', 'details', 'status', 'previousStatus', 'priority', 'dueOn',
                'completedAt', 'deletedAt', 'source', 'createdAt'
            ];
            required_fields := array['title', 'details', 'status', 'priority', 'source', 'createdAt'];
        when 'appearance' then
            allowed_fields := array['schemaVersion', 'preferences', 'deletedAt'];
            required_fields := array['schemaVersion', 'preferences'];
        when 'primaryGoal' then
            allowed_fields := array[
                'title', 'metric', 'currentValue', 'targetValue', 'unit', 'dueOn', 'deletedAt'
            ];
            required_fields := array['title', 'metric', 'unit', 'dueOn'];
        when 'milestone' then
            allowed_fields := array['title', 'dueAt', 'deletedAt', 'createdAt'];
            required_fields := array['title', 'dueAt', 'createdAt'];
        when 'asset' then
            allowed_fields := array[
                'kind', 'storagePath', 'contentType', 'byteSize', 'sha256', 'deletedAt'
            ];
            required_fields := array['kind', 'storagePath', 'contentType', 'byteSize', 'sha256'];
        end case;

        if entity_type = 'asset' and not exists (
            select 1
            from private.product_capabilities as capability
            where capability.singleton
              and capability.asset_storage_enabled
              and capability.asset_export_verified
              and capability.asset_erasure_verified
        ) then
            raise exception using
                errcode = 'PT503',
                message = 'asset sync is disabled until private export and erasure are verified';
        end if;

        if exists (
            select 1
            from jsonb_array_elements_text(changed_fields) as field(value)
            where not field.value = any(allowed_fields)
        ) then
            raise exception using errcode = '22023', message = 'changed field is not allowed for this entity';
        end if;

        if action = 'delete' then
            if jsonb_array_length(changed_fields) <> 1
               or changed_fields ->> 0 <> 'deletedAt'
               or not 'deletedAt' = any(allowed_fields) then
                raise exception using errcode = '22023', message = 'delete operations may change only deletedAt';
            end if;
        else
            if exists (
                select 1
                from jsonb_array_elements_text(changed_fields) as field(value)
                where not payload ? field.value
            ) or exists (
                select 1
                from jsonb_object_keys(payload) as payload_field(field_name)
                where not changed_fields ? payload_field.field_name
            ) then
                raise exception using errcode = '22023', message = 'payload keys must match changedFields exactly';
            end if;

            if exists (
                select 1
                from jsonb_array_elements_text(changed_fields) as field(value)
                where not case entity_type
                    when 'workspace' then
                        field.value = 'name'
                        and jsonb_typeof(payload -> field.value) = 'string'
                    when 'move' then case
                        when field.value in ('title', 'details', 'status', 'priority', 'source', 'createdAt')
                            then jsonb_typeof(payload -> field.value) = 'string'
                        when field.value = 'previousStatus'
                            then jsonb_typeof(payload -> field.value) in ('string', 'null')
                        when field.value in ('dueOn', 'completedAt', 'deletedAt')
                            then jsonb_typeof(payload -> field.value) in ('string', 'null')
                        else false
                    end
                    when 'appearance' then case
                        when field.value = 'schemaVersion' then
                            jsonb_typeof(payload -> field.value) = 'number'
                            and (payload ->> field.value) ~ '^-?(0|[1-9][0-9]*)(\.0+)?$'
                        when field.value = 'preferences'
                            then jsonb_typeof(payload -> field.value) = 'object'
                        when field.value = 'deletedAt'
                            then jsonb_typeof(payload -> field.value) in ('string', 'null')
                        else false
                    end
                    when 'primaryGoal' then case
                        when field.value in ('title', 'metric', 'unit', 'dueOn')
                            then jsonb_typeof(payload -> field.value) = 'string'
                        when field.value in ('currentValue', 'targetValue')
                            then jsonb_typeof(payload -> field.value) in ('number', 'null')
                        when field.value = 'deletedAt'
                            then jsonb_typeof(payload -> field.value) in ('string', 'null')
                        else false
                    end
                    when 'milestone' then case
                        when field.value in ('title', 'dueAt', 'createdAt')
                            then jsonb_typeof(payload -> field.value) = 'string'
                        when field.value = 'deletedAt'
                            then jsonb_typeof(payload -> field.value) in ('string', 'null')
                        else false
                    end
                    when 'asset' then case
                        when field.value in ('kind', 'storagePath', 'contentType', 'sha256')
                            then jsonb_typeof(payload -> field.value) = 'string'
                        when field.value = 'byteSize' then
                            jsonb_typeof(payload -> field.value) = 'number'
                            and (payload ->> field.value) ~ '^-?(0|[1-9][0-9]*)(\.0+)?$'
                        when field.value = 'deletedAt'
                            then jsonb_typeof(payload -> field.value) in ('string', 'null')
                        else false
                    end
                    else false
                end
            ) then
                raise exception using errcode = '22023', message = 'payload field has an invalid JSON type';
            end if;

            if entity_type = 'appearance'
               and changed_fields ? 'preferences'
               and octet_length((payload -> 'preferences')::text) > 262144 then
                raise exception using errcode = '22023', message = 'appearance preferences exceed the sync limit';
            end if;

            if entity_type = 'workspace'
               and changed_fields ? 'name'
               and char_length(btrim(payload ->> 'name')) not between 1 and 120 then
                raise exception using errcode = '22023', message = 'workspace name is invalid';
            elsif entity_type = 'move' then
                if changed_fields ? 'title'
                   and char_length(btrim(payload ->> 'title')) not between 1 and 500 then
                    raise exception using errcode = '22023', message = 'Move title is invalid';
                end if;
                if changed_fields ? 'details' and char_length(payload ->> 'details') > 20000 then
                    raise exception using errcode = '22023', message = 'Move details exceed the sync limit';
                end if;
                if changed_fields ? 'status'
                   and payload ->> 'status' not in ('doing', 'next', 'blocked', 'done') then
                    raise exception using errcode = '22023', message = 'Move status is invalid';
                end if;
                if changed_fields ? 'previousStatus'
                   and payload ->> 'previousStatus' is not null
                   and payload ->> 'previousStatus' not in ('doing', 'next', 'blocked', 'done') then
                    raise exception using errcode = '22023', message = 'Move previous status is invalid';
                end if;
                if changed_fields ? 'priority'
                   and payload ->> 'priority' not in ('P0', 'P1', 'P2', 'P3') then
                    raise exception using errcode = '22023', message = 'Move priority is invalid';
                end if;
                if changed_fields ? 'source'
                   and char_length(btrim(payload ->> 'source')) not between 1 and 64 then
                    raise exception using errcode = '22023', message = 'Move source is invalid';
                end if;
            elsif entity_type = 'appearance'
                  and changed_fields ? 'schemaVersion'
                  and (payload ->> 'schemaVersion')::numeric not between 1 and 2147483647 then
                raise exception using errcode = '22023', message = 'Appearance schema version is invalid';
            elsif entity_type = 'primaryGoal' then
                if changed_fields ? 'title'
                   and char_length(btrim(payload ->> 'title')) not between 1 and 500 then
                    raise exception using errcode = '22023', message = 'Primary goal title is invalid';
                end if;
                if changed_fields ? 'metric' and char_length(payload ->> 'metric') > 120 then
                    raise exception using errcode = '22023', message = 'Primary goal metric exceeds the sync limit';
                end if;
                if changed_fields ? 'unit'
                   and payload ->> 'unit' not in ('usd', 'inr', 'number', 'percent') then
                    raise exception using errcode = '22023', message = 'Primary goal unit is invalid';
                end if;
                if exists (
                    select 1
                    from jsonb_array_elements_text(changed_fields) as field(value)
                    where field.value in ('currentValue', 'targetValue')
                      and payload ->> field.value is not null
                      and (
                          (payload ->> field.value)::numeric < 0
                          or (payload ->> field.value)::numeric
                              > 9999999999999999999999.99999999::numeric
                          or scale((payload ->> field.value)::numeric) > 8
                      )
                ) then
                    raise exception using errcode = '22023', message = 'Primary goal value exceeds numeric(30,8)';
                end if;
            elsif entity_type = 'milestone' then
                if changed_fields ? 'title'
                   and char_length(btrim(payload ->> 'title')) not between 1 and 500 then
                    raise exception using errcode = '22023', message = 'Milestone title is invalid';
                end if;
            elsif entity_type = 'asset' then
                if changed_fields ? 'kind' and payload ->> 'kind' <> 'visionImage' then
                    raise exception using errcode = '22023', message = 'Asset kind is invalid';
                end if;
                if changed_fields ? 'storagePath'
                   and payload ->> 'storagePath' <> (
                       'workspaces/' || p_workspace_id::text || '/vision-images/' || entity_id::text || '.jpg'
                   ) then
                    raise exception using errcode = '22023', message = 'Asset storage path is invalid';
                end if;
                if changed_fields ? 'contentType'
                   and payload ->> 'contentType' <> 'image/jpeg' then
                    raise exception using errcode = '22023', message = 'Asset content type is invalid';
                end if;
                if changed_fields ? 'byteSize'
                   and (payload ->> 'byteSize')::numeric not between 1 and 5242880 then
                    raise exception using errcode = '22023', message = 'Asset byte size is invalid';
                end if;
                if changed_fields ? 'sha256'
                   and payload ->> 'sha256' !~ '^[a-f0-9]{64}$' then
                    raise exception using errcode = '22023', message = 'Asset digest is invalid';
                end if;
            end if;

            begin
                if entity_type = 'move' then
                    if changed_fields ? 'dueOn' and payload ->> 'dueOn' is not null
                       and not private.is_canonical_date_v1(payload ->> 'dueOn') then
                        raise exception using errcode = '22023', message = 'Move dueOn must be canonical YYYY-MM-DD';
                    end if;
                    if changed_fields ? 'completedAt' and payload ->> 'completedAt' is not null
                       and not private.is_canonical_timestamp_v1(payload ->> 'completedAt') then
                        raise exception using errcode = '22023', message = 'Move completedAt must be finite';
                    end if;
                    if changed_fields ? 'deletedAt' and payload ->> 'deletedAt' is not null
                       and not private.is_canonical_timestamp_v1(payload ->> 'deletedAt') then
                        raise exception using errcode = '22023', message = 'Move deletedAt must be finite';
                    end if;
                    if changed_fields ? 'createdAt'
                       and not private.is_canonical_timestamp_v1(payload ->> 'createdAt') then
                        raise exception using errcode = '22023', message = 'Move createdAt must be finite';
                    end if;
                elsif entity_type = 'appearance' then
                    if changed_fields ? 'deletedAt' and payload ->> 'deletedAt' is not null
                       and not private.is_canonical_timestamp_v1(payload ->> 'deletedAt') then
                        raise exception using errcode = '22023', message = 'Appearance deletedAt must be finite';
                    end if;
                elsif entity_type = 'primaryGoal' then
                    if changed_fields ? 'dueOn'
                       and not private.is_canonical_date_v1(payload ->> 'dueOn') then
                        raise exception using errcode = '22023', message = 'Primary goal dueOn must be canonical YYYY-MM-DD';
                    end if;
                    if changed_fields ? 'deletedAt' and payload ->> 'deletedAt' is not null
                       and not private.is_canonical_timestamp_v1(payload ->> 'deletedAt') then
                        raise exception using errcode = '22023', message = 'Primary goal deletedAt must be finite';
                    end if;
                elsif entity_type = 'milestone' then
                    if changed_fields ? 'dueAt'
                       and not private.is_canonical_timestamp_v1(payload ->> 'dueAt') then
                        raise exception using errcode = '22023', message = 'Milestone dueAt must be finite';
                    end if;
                    if changed_fields ? 'createdAt'
                       and not private.is_canonical_timestamp_v1(payload ->> 'createdAt') then
                        raise exception using errcode = '22023', message = 'Milestone createdAt must be finite';
                    end if;
                    if changed_fields ? 'deletedAt' and payload ->> 'deletedAt' is not null
                       and not private.is_canonical_timestamp_v1(payload ->> 'deletedAt') then
                        raise exception using errcode = '22023', message = 'Milestone deletedAt must be finite';
                    end if;
                elsif entity_type = 'asset'
                      and changed_fields ? 'deletedAt'
                      and payload ->> 'deletedAt' is not null
                      and not private.is_canonical_timestamp_v1(payload ->> 'deletedAt') then
                    raise exception using errcode = '22023', message = 'Asset deletedAt must be finite';
                end if;
            exception
                when invalid_text_representation or datetime_field_overflow then
                    raise exception using errcode = '22023', message = 'payload contains an invalid date or timestamp';
            end;
        end if;

        perform pg_advisory_xact_lock(
            hashtextextended(p_workspace_id::text || ':' || operation_id::text, 0)
        );

        select receipt.operation_envelope, receipt.result
        into operation_receipt
        from private.sync_operation_receipts as receipt
        where receipt.workspace_id = p_workspace_id
          and receipt.operation_id = operation_id;

        if found then
            if operation_receipt.operation_envelope <> operation then
                raise exception using
                    errcode = '22023',
                    message = 'operation ID was reused with different content';
            end if;

            result_item := operation_receipt.result;
            if result_item ->> 'status' = 'accepted' then
                result_item := jsonb_set(result_item, '{status}', '"duplicate"'::jsonb);
            end if;
            results := results || jsonb_build_array(result_item);
            continue;
        end if;

        perform pg_advisory_xact_lock(
            hashtextextended(p_workspace_id::text || ':' || entity_type || ':' || entity_id::text, 0)
        );

        server_record := private.entity_record(p_workspace_id, entity_type, entity_id);
        current_revision := coalesce((server_record ->> 'revision')::bigint, 0);
        current_field_clocks := coalesce(server_record -> 'fieldClocks', '{}'::jsonb);
        current_field_writers := private.entity_field_writers(
            p_workspace_id,
            entity_type,
            entity_id
        );

        if action = 'upsert' and current_revision = 0 and exists (
            select 1
            from unnest(required_fields) as required(field_name)
            where not changed_fields ? required.field_name
        ) then
            raise exception using errcode = '22023', message = 'new record is missing required changed fields';
        end if;
        if current_revision > 0 and changed_fields ? 'createdAt' then
            raise exception using errcode = '22023', message = 'createdAt is immutable';
        end if;

        if (action = 'delete' and current_revision = 0)
           or base_revision > current_revision
           or (base_revision = 0 and current_revision > 0)
           or (
               base_revision < current_revision
               and exists (
                   select 1
                   from public.change_log as newer_change
                   where newer_change.workspace_id = p_workspace_id
                     and newer_change.entity_type = entity_type
                     and newer_change.entity_id = entity_id
                     and newer_change.revision > base_revision
                     and newer_change.changed_fields && changed_field_names
               )
           )
           or not private.incoming_field_clocks_win(
               current_field_clocks,
               current_field_writers,
               field_clocks,
               changed_fields,
               operation_id
           ) then
            select coalesce(
                jsonb_agg(to_jsonb(field.value) order by field.ordinality),
                '[]'::jsonb
            )
            into conflicting_fields
            from jsonb_array_elements_text(changed_fields)
                with ordinality as field(value, ordinality)
            where current_field_clocks ? field.value;

            result_item := jsonb_build_object(
                'operationId', operation_id,
                'status', 'conflict',
                'conflict', jsonb_build_object(
                    'operationId', operation_id,
                    'entityType', entity_type,
                    'entityId', entity_id,
                    'baseRevision', base_revision,
                    'currentRevision', current_revision,
                    'reason', case
                        when action = 'delete' and current_revision = 0 then 'missingRecord'
                        when base_revision > current_revision
                          or (base_revision = 0 and current_revision > 0) then 'revisionMismatch'
                        when base_revision < current_revision
                          and exists (
                              select 1
                              from public.change_log as newer_change
                              where newer_change.workspace_id = p_workspace_id
                                and newer_change.entity_type = entity_type
                                and newer_change.entity_id = entity_id
                                and newer_change.revision > base_revision
                                and newer_change.changed_fields && changed_field_names
                          ) then 'overlappingChanges'
                        else 'fieldClockLost'
                    end,
                    'conflictingFields', conflicting_fields,
                    'serverRecord', server_record
                )
            );
            insert into private.sync_operation_receipts (
                workspace_id,
                operation_id,
                operation_envelope,
                result
            ) values (p_workspace_id, operation_id, operation, result_item);
            results := results || jsonb_build_array(result_item);
            continue;
        end if;

        next_revision := current_revision + 1;
        changed_at := clock_timestamp();
        merged_field_clocks := current_field_clocks || field_clocks;
        merged_field_writers := current_field_writers
            || private.operation_field_writers(changed_fields, operation_id);

        case entity_type
        when 'workspace' then
            if action = 'delete' then
                raise exception using errcode = '22023', message = 'use erase_workspace for workspace deletion';
            end if;
            update public.workspaces
            set name = btrim(payload ->> 'name'),
                revision = next_revision,
                field_clocks = merged_field_clocks,
                field_writers = merged_field_writers,
                updated_at = changed_at
            where id = p_workspace_id;

        when 'move' then
            if action = 'upsert' and current_revision = 0 then
                insert into public.moves (
                    id, workspace_id, title, details, status, previous_status, priority,
                    due_on, completed_at, deleted_at, source, revision, field_clocks,
                    field_writers, writer_device_id, created_at, updated_at
                ) values (
                    entity_id,
                    p_workspace_id,
                    btrim(payload ->> 'title'),
                    coalesce(payload ->> 'details', ''),
                    payload ->> 'status',
                    nullif(payload ->> 'previousStatus', ''),
                    payload ->> 'priority',
                    (payload ->> 'dueOn')::date,
                    (payload ->> 'completedAt')::timestamptz,
                    (payload ->> 'deletedAt')::timestamptz,
                    payload ->> 'source',
                    next_revision,
                    merged_field_clocks,
                    merged_field_writers,
                    p_device_id,
                    least(coalesce((payload ->> 'createdAt')::timestamptz, occurred_at), changed_at),
                    changed_at
                );
            elsif action = 'upsert' then
                update public.moves
                set title = case when changed_fields ? 'title' then btrim(payload ->> 'title') else title end,
                    details = case when changed_fields ? 'details' then coalesce(payload ->> 'details', '') else details end,
                    status = case when changed_fields ? 'status' then payload ->> 'status' else status end,
                    previous_status = case
                        when changed_fields ? 'previousStatus' then nullif(payload ->> 'previousStatus', '')
                        else previous_status
                    end,
                    priority = case when changed_fields ? 'priority' then payload ->> 'priority' else priority end,
                    due_on = case when changed_fields ? 'dueOn' then (payload ->> 'dueOn')::date else due_on end,
                    completed_at = case
                        when changed_fields ? 'completedAt' then (payload ->> 'completedAt')::timestamptz
                        else completed_at
                    end,
                    deleted_at = case
                        when changed_fields ? 'deletedAt' then (payload ->> 'deletedAt')::timestamptz
                        else deleted_at
                    end,
                    source = case when changed_fields ? 'source' then payload ->> 'source' else source end,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            else
                update public.moves
                set deleted_at = (field_clocks ->> 'deletedAt')::timestamptz,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            end if;

        when 'appearance' then
            if action = 'upsert' and current_revision = 0 then
                insert into public.appearance (
                    id, workspace_id, schema_version, preferences, deleted_at, revision,
                    field_clocks, field_writers, writer_device_id, created_at, updated_at
                ) values (
                    entity_id,
                    p_workspace_id,
                    (payload ->> 'schemaVersion')::integer,
                    payload -> 'preferences',
                    (payload ->> 'deletedAt')::timestamptz,
                    next_revision,
                    merged_field_clocks,
                    merged_field_writers,
                    p_device_id,
                    changed_at,
                    changed_at
                );
            elsif action = 'upsert' then
                update public.appearance
                set schema_version = case
                        when changed_fields ? 'schemaVersion' then (payload ->> 'schemaVersion')::integer
                        else schema_version
                    end,
                    preferences = case
                        when changed_fields ? 'preferences' then payload -> 'preferences'
                        else preferences
                    end,
                    deleted_at = case
                        when changed_fields ? 'deletedAt' then (payload ->> 'deletedAt')::timestamptz
                        else deleted_at
                    end,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            else
                update public.appearance
                set deleted_at = (field_clocks ->> 'deletedAt')::timestamptz,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            end if;

        when 'primaryGoal' then
            if action = 'upsert' and current_revision = 0 then
                insert into public.primary_goals (
                    id, workspace_id, title, metric, current_value, target_value, unit,
                    due_on, deleted_at, revision, field_clocks, field_writers,
                    writer_device_id, created_at, updated_at
                ) values (
                    entity_id,
                    p_workspace_id,
                    btrim(payload ->> 'title'),
                    coalesce(payload ->> 'metric', ''),
                    (payload ->> 'currentValue')::numeric,
                    (payload ->> 'targetValue')::numeric,
                    payload ->> 'unit',
                    (payload ->> 'dueOn')::date,
                    (payload ->> 'deletedAt')::timestamptz,
                    next_revision,
                    merged_field_clocks,
                    merged_field_writers,
                    p_device_id,
                    changed_at,
                    changed_at
                );
            elsif action = 'upsert' then
                update public.primary_goals
                set title = case when changed_fields ? 'title' then btrim(payload ->> 'title') else title end,
                    metric = case when changed_fields ? 'metric' then coalesce(payload ->> 'metric', '') else metric end,
                    current_value = case
                        when changed_fields ? 'currentValue' then (payload ->> 'currentValue')::numeric
                        else current_value
                    end,
                    target_value = case
                        when changed_fields ? 'targetValue' then (payload ->> 'targetValue')::numeric
                        else target_value
                    end,
                    unit = case when changed_fields ? 'unit' then payload ->> 'unit' else unit end,
                    due_on = case when changed_fields ? 'dueOn' then (payload ->> 'dueOn')::date else due_on end,
                    deleted_at = case
                        when changed_fields ? 'deletedAt' then (payload ->> 'deletedAt')::timestamptz
                        else deleted_at
                    end,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            else
                update public.primary_goals
                set deleted_at = (field_clocks ->> 'deletedAt')::timestamptz,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            end if;

        when 'milestone' then
            if action = 'upsert' and current_revision = 0 then
                insert into public.milestones (
                    id, workspace_id, title, due_at, deleted_at, revision,
                    field_clocks, field_writers, writer_device_id, created_at, updated_at
                ) values (
                    entity_id,
                    p_workspace_id,
                    btrim(payload ->> 'title'),
                    (payload ->> 'dueAt')::timestamptz,
                    (payload ->> 'deletedAt')::timestamptz,
                    next_revision,
                    merged_field_clocks,
                    merged_field_writers,
                    p_device_id,
                    least((payload ->> 'createdAt')::timestamptz, changed_at),
                    changed_at
                );
            elsif action = 'upsert' then
                update public.milestones
                set title = case when changed_fields ? 'title' then btrim(payload ->> 'title') else title end,
                    due_at = case
                        when changed_fields ? 'dueAt' then (payload ->> 'dueAt')::timestamptz
                        else due_at
                    end,
                    deleted_at = case
                        when changed_fields ? 'deletedAt' then (payload ->> 'deletedAt')::timestamptz
                        else deleted_at
                    end,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            else
                update public.milestones
                set deleted_at = (field_clocks ->> 'deletedAt')::timestamptz,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            end if;

        when 'asset' then
            if action = 'upsert' and current_revision = 0 then
                insert into public.assets (
                    id, workspace_id, kind, storage_path, content_type, byte_size,
                    sha256, deleted_at, revision, field_clocks, field_writers,
                    writer_device_id, created_at, updated_at
                ) values (
                    entity_id,
                    p_workspace_id,
                    payload ->> 'kind',
                    payload ->> 'storagePath',
                    payload ->> 'contentType',
                    (payload ->> 'byteSize')::bigint,
                    payload ->> 'sha256',
                    (payload ->> 'deletedAt')::timestamptz,
                    next_revision,
                    merged_field_clocks,
                    merged_field_writers,
                    p_device_id,
                    changed_at,
                    changed_at
                );
            elsif action = 'upsert' then
                update public.assets
                set kind = case when changed_fields ? 'kind' then payload ->> 'kind' else kind end,
                    storage_path = case
                        when changed_fields ? 'storagePath' then payload ->> 'storagePath'
                        else storage_path
                    end,
                    content_type = case
                        when changed_fields ? 'contentType' then payload ->> 'contentType'
                        else content_type
                    end,
                    byte_size = case
                        when changed_fields ? 'byteSize' then (payload ->> 'byteSize')::bigint
                        else byte_size
                    end,
                    sha256 = case when changed_fields ? 'sha256' then payload ->> 'sha256' else sha256 end,
                    deleted_at = case
                        when changed_fields ? 'deletedAt' then (payload ->> 'deletedAt')::timestamptz
                        else deleted_at
                    end,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            else
                update public.assets
                set deleted_at = (field_clocks ->> 'deletedAt')::timestamptz,
                    revision = next_revision,
                    field_clocks = merged_field_clocks,
                    field_writers = merged_field_writers,
                    writer_device_id = p_device_id,
                    updated_at = changed_at
                where workspace_id = p_workspace_id and id = entity_id;
            end if;
        end case;

        server_record := private.entity_record(p_workspace_id, entity_type, entity_id);

        insert into public.change_log (
            workspace_id,
            operation_id,
            entity_type,
            entity_id,
            action,
            revision,
            changed_fields,
            record,
            actor_account_id,
            device_id,
            changed_at
        ) values (
            p_workspace_id,
            operation_id,
            entity_type,
            entity_id,
            action,
            next_revision,
            changed_field_names,
            server_record,
            account_id,
            p_device_id,
            changed_at
        ) returning cursor into change_cursor;

        insert into public.activity_events (
            workspace_id,
            actor_account_id,
            device_id,
            operation_id,
            kind,
            entity_type,
            entity_id,
            occurred_at,
            metadata
        ) values (
            p_workspace_id,
            account_id,
            p_device_id,
            operation_id,
            lower(entity_type) || case action when 'upsert' then '.upserted' else '.deleted' end,
            entity_type,
            entity_id,
            changed_at,
            '{}'::jsonb
        );

        result_item := jsonb_build_object(
            'operationId', operation_id,
            'status', 'accepted',
            'revision', next_revision,
            'cursor', change_cursor
        );
        insert into private.sync_operation_receipts (
            workspace_id,
            operation_id,
            operation_envelope,
            result
        ) values (p_workspace_id, operation_id, operation, result_item);
        results := results || jsonb_build_array(result_item);
    end loop;

    select coalesce(max(change.cursor), 0)
    into latest_cursor
    from public.change_log as change
    where change.workspace_id = p_workspace_id;

    insert into public.device_cursors (workspace_id, account_id, device_id, cursor, last_seen_at)
    values (p_workspace_id, account_id, p_device_id, 0, now())
    on conflict (workspace_id, account_id, device_id) do update
    set last_seen_at = excluded.last_seen_at;

    return jsonb_build_object(
        'contractVersion', 1,
        'workspaceId', p_workspace_id,
        'latestCursor', latest_cursor,
        'results', results
    );
end;
$$;

create or replace function public.pull_changes(
    p_workspace_id uuid,
    p_device_id uuid,
    p_cursor bigint,
    p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    account_id uuid := private.require_workspace_owner(p_workspace_id);
    changes jsonb := '[]'::jsonb;
    next_cursor bigint := p_cursor;
    latest_cursor bigint := 0;
    has_more boolean := false;
begin
    if p_device_id is null
       or p_cursor is null
       or p_cursor < 0
       or p_limit is null
       or p_limit not between 1 and 500 then
        raise exception using errcode = '22023', message = 'pull arguments are invalid';
    end if;

    select coalesce(max(change.cursor), 0)
    into latest_cursor
    from public.change_log as change
    where change.workspace_id = p_workspace_id;

    if p_cursor > latest_cursor then
        raise exception using errcode = '22023', message = 'pull cursor is ahead of the workspace feed';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
        'cursor', page.cursor,
        'operationId', page.operation_id,
        'entityType', page.entity_type,
        'entityId', page.entity_id,
        'action', page.action,
        'revision', page.revision,
        'changedFields', to_jsonb(page.changed_fields),
        'changedAt', page.changed_at,
        'record', page.record
    ) order by page.cursor), '[]'::jsonb),
    coalesce(max(page.cursor), p_cursor)
    into changes, next_cursor
    from (
        select change.*
        from public.change_log as change
        where change.workspace_id = p_workspace_id
          and change.cursor > p_cursor
        order by change.cursor
        limit p_limit
    ) as page;

    select coalesce(max(change.cursor), 0)
    into latest_cursor
    from public.change_log as change
    where change.workspace_id = p_workspace_id;

    has_more := latest_cursor > next_cursor;

    insert into public.device_cursors (workspace_id, account_id, device_id, cursor, last_seen_at)
    values (p_workspace_id, account_id, p_device_id, next_cursor, now())
    on conflict (workspace_id, account_id, device_id) do update
    set cursor = greatest(public.device_cursors.cursor, excluded.cursor),
        last_seen_at = excluded.last_seen_at;

    return jsonb_build_object(
        'contractVersion', 1,
        'workspaceId', p_workspace_id,
        'fromCursor', p_cursor,
        'nextCursor', next_cursor,
        'latestCursor', latest_cursor,
        'hasMore', has_more,
        'changes', changes
    );
end;
$$;

create or replace function public.export_workspace(p_workspace_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    account_id uuid := private.require_workspace_owner(p_workspace_id);
    asset_manifest jsonb := '[]'::jsonb;
    asset_export_state text := 'notRequired';
begin
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', asset.id,
        'storagePath', asset.storage_path,
        'contentType', asset.content_type,
        'byteSize', asset.byte_size,
        'sha256', asset.sha256,
        'deletedAt', asset.deleted_at
    ) order by asset.id), '[]'::jsonb)
    into asset_manifest
    from public.assets as asset
    where asset.workspace_id = p_workspace_id;

    if jsonb_array_length(asset_manifest) > 0 then
        if exists (
            select 1
            from private.workspace_asset_transfers as transfer
            where transfer.workspace_id = p_workspace_id
              and transfer.owner_account_id = account_id
              and transfer.manifest = asset_manifest
              and transfer.export_verified_at is not null
        ) then
            asset_export_state := 'verified';
        else
            asset_export_state := 'requiresPrivateStorageAdapter';
        end if;
    end if;

    return jsonb_build_object(
        'contractVersion', 1,
        'exportedAt', now(),
        'workspace', private.entity_record(p_workspace_id, 'workspace', p_workspace_id),
        'moves', coalesce((
            select jsonb_agg(private.entity_record(p_workspace_id, 'move', move.id) order by move.created_at, move.id)
            from public.moves as move where move.workspace_id = p_workspace_id
        ), '[]'::jsonb),
        'appearance', coalesce((
            select jsonb_agg(private.entity_record(p_workspace_id, 'appearance', item.id) order by item.created_at, item.id)
            from public.appearance as item where item.workspace_id = p_workspace_id
        ), '[]'::jsonb),
        'primaryGoals', coalesce((
            select jsonb_agg(private.entity_record(p_workspace_id, 'primaryGoal', goal.id) order by goal.created_at, goal.id)
            from public.primary_goals as goal where goal.workspace_id = p_workspace_id
        ), '[]'::jsonb),
        'milestones', coalesce((
            select jsonb_agg(private.entity_record(p_workspace_id, 'milestone', milestone.id) order by milestone.created_at, milestone.id)
            from public.milestones as milestone where milestone.workspace_id = p_workspace_id
        ), '[]'::jsonb),
        'assets', coalesce((
            select jsonb_agg(private.entity_record(p_workspace_id, 'asset', asset.id) order by asset.created_at, asset.id)
            from public.assets as asset where asset.workspace_id = p_workspace_id
        ), '[]'::jsonb),
        'assetTransfer', jsonb_build_object(
            'state', asset_export_state,
            'manifest', asset_manifest
        ),
        'activityEvents', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', event.id,
                'workspaceId', event.workspace_id,
                'accountId', event.actor_account_id,
                'deviceId', event.device_id,
                'kind', event.kind,
                'entityType', event.entity_type,
                'entityId', event.entity_id,
                'occurredAt', event.occurred_at,
                'metadata', event.metadata
            ) order by event.sequence)
            from public.activity_events as event
            where event.workspace_id = p_workspace_id
        ), '[]'::jsonb)
    );
end;
$$;

create or replace function public.erase_workspace(
    p_workspace_id uuid,
    p_confirm_workspace_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    account_id uuid := auth.uid();
    erased_at timestamptz := clock_timestamp();
    prior_receipt record;
    asset_manifest jsonb := '[]'::jsonb;
    asset_object_count integer := 0;
    asset_cleanup_state text := 'notRequired';
begin
    if account_id is null then
        raise exception using errcode = '28000', message = 'authentication required';
    end if;
    if p_workspace_id is distinct from p_confirm_workspace_id then
        raise exception using errcode = '22023', message = 'workspace erasure confirmation does not match';
    end if;

    perform pg_advisory_xact_lock(hashtextextended('erase:' || p_workspace_id::text, 0));

    select receipt.erased_at, receipt.asset_object_count, receipt.asset_cleanup_state
    into prior_receipt
    from private.workspace_erasure_receipts as receipt
    where receipt.workspace_id = p_workspace_id
      and receipt.owner_account_id = account_id;

    if found then
        return jsonb_build_object(
            'contractVersion', 1,
            'workspaceId', p_workspace_id,
            'erasedAt', prior_receipt.erased_at,
            'assetObjectCount', prior_receipt.asset_object_count,
            'assetCleanupState', prior_receipt.asset_cleanup_state
        );
    end if;

    if exists (
        select 1
        from private.workspace_erasure_receipts as receipt
        where receipt.workspace_id = p_workspace_id
    ) then
        raise exception using errcode = '42501', message = 'workspace access denied';
    end if;

    perform private.require_workspace_owner(p_workspace_id);

    select coalesce(jsonb_agg(jsonb_build_object(
        'id', asset.id,
        'storagePath', asset.storage_path,
        'contentType', asset.content_type,
        'byteSize', asset.byte_size,
        'sha256', asset.sha256,
        'deletedAt', asset.deleted_at
    ) order by asset.id), '[]'::jsonb)
    into asset_manifest
    from public.assets as asset
    where asset.workspace_id = p_workspace_id;

    asset_object_count := jsonb_array_length(asset_manifest);
    if asset_object_count > 0 then
        if not exists (
            select 1
            from private.product_capabilities as capability
            where capability.singleton
              and capability.asset_storage_enabled
              and capability.asset_erasure_verified
        ) or not exists (
            select 1
            from private.workspace_asset_transfers as transfer
            where transfer.workspace_id = p_workspace_id
              and transfer.owner_account_id = account_id
              and transfer.manifest = asset_manifest
              and transfer.deletion_verified_at is not null
        ) then
            raise exception using
                errcode = 'PT503',
                message = 'private asset deletion has not been verified for this workspace';
        end if;
        asset_cleanup_state := 'verified';
    end if;

    insert into private.workspace_erasure_receipts (
        workspace_id,
        owner_account_id,
        erased_at,
        asset_object_count,
        asset_cleanup_state
    ) values (
        p_workspace_id,
        account_id,
        erased_at,
        asset_object_count,
        asset_cleanup_state
    );

    delete from public.workspaces
    where id = p_workspace_id
      and owner_account_id = account_id;

    if not found then
        raise exception using errcode = '42501', message = 'workspace access denied';
    end if;

    return jsonb_build_object(
        'contractVersion', 1,
        'workspaceId', p_workspace_id,
        'erasedAt', erased_at,
        'assetObjectCount', asset_object_count,
        'assetCleanupState', asset_cleanup_state
    );
end;
$$;

revoke all on function private.require_workspace_owner(uuid) from public, anon, authenticated;
revoke all on function private.entity_record(uuid, text, uuid) from public, anon, authenticated;
revoke all on function private.entity_field_writers(uuid, text, uuid) from public, anon, authenticated;
revoke all on function private.is_canonical_date_v1(text) from public, anon, authenticated;
revoke all on function private.is_canonical_timestamp_v1(text) from public, anon, authenticated;
revoke all on function private.operation_field_writers(jsonb, uuid) from public, anon, authenticated;
revoke all on function private.incoming_field_clocks_win(jsonb, jsonb, jsonb, jsonb, uuid)
    from public, anon, authenticated;

revoke all on function public.bootstrap_workspace(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.push_operations(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.pull_changes(uuid, uuid, bigint, integer) from public, anon, authenticated;
revoke all on function public.export_workspace(uuid) from public, anon, authenticated;
revoke all on function public.erase_workspace(uuid, uuid) from public, anon, authenticated;

grant execute on function public.bootstrap_workspace(uuid, uuid, text, text) to authenticated;
grant execute on function public.push_operations(uuid, uuid, jsonb) to authenticated;
grant execute on function public.pull_changes(uuid, uuid, bigint, integer) to authenticated;
grant execute on function public.export_workspace(uuid) to authenticated;
grant execute on function public.erase_workspace(uuid, uuid) to authenticated;

commit;
