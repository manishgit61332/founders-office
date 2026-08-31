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
    workspace_was_created boolean := false;
    latest_cursor bigint := 0;
    clean_workspace_name text := btrim(p_workspace_name);
    clean_display_name text := nullif(btrim(p_display_name), '');
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
       and (clean_display_name is null or char_length(clean_display_name) > 120) then
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
            raise exception using errcode = '42501', message = 'workspace is unavailable';
        end;
        workspace_was_created := true;
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
            jsonb_build_object('contractVersion', 1)
        );
    end if;

    select coalesce(max(change.cursor), 0)
    into latest_cursor
    from public.change_log as change
    where change.workspace_id = workspace_id;

    insert into public.device_cursors (workspace_id, account_id, device_id, cursor, last_seen_at)
    values (workspace_id, account_id, p_device_id, latest_cursor, now())
    on conflict (workspace_id, account_id, device_id) do update
    set cursor = greatest(public.device_cursors.cursor, excluded.cursor),
        last_seen_at = excluded.last_seen_at;

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
    duplicate_change record;
    results jsonb := '[]'::jsonb;
begin
    if p_device_id is null then
        raise exception using errcode = '22023', message = 'device ID is required';
    end if;
    if p_operations is null
       or jsonb_typeof(p_operations) <> 'array'
       or jsonb_array_length(p_operations) not between 1 and 100 then
        raise exception using errcode = '22023', message = 'operations must contain between 1 and 100 items';
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
        exception when invalid_text_representation or numeric_value_out_of_range then
            raise exception using errcode = '22023', message = 'operation contains an invalid identifier, revision, or timestamp';
        end;

        if entity_type is null
           or entity_type not in ('workspace', 'move', 'appearance', 'primaryGoal', 'asset')
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
               or not isfinite((field_clocks ->> field.value)::timestamptz)
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
        when 'asset' then
            allowed_fields := array[
                'kind', 'storagePath', 'contentType', 'byteSize', 'sha256', 'deletedAt'
            ];
            required_fields := array['kind', 'storagePath', 'contentType', 'byteSize', 'sha256'];
        end case;

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
        end if;

        perform pg_advisory_xact_lock(
            hashtextextended(p_workspace_id::text || ':' || operation_id::text, 0)
        );
        perform pg_advisory_xact_lock(
            hashtextextended(p_workspace_id::text || ':' || entity_type || ':' || entity_id::text, 0)
        );

        select change.revision, change.cursor, change.record
        into duplicate_change
        from public.change_log as change
        where change.workspace_id = p_workspace_id
          and change.operation_id = operation_id;

        if found then
            results := results || jsonb_build_array(jsonb_build_object(
                'operationId', operation_id,
                'status', 'duplicate',
                'revision', duplicate_change.revision,
                'cursor', duplicate_change.cursor
            ));
            continue;
        end if;

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
            results := results || jsonb_build_array(jsonb_build_object(
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
                    'serverRecord', server_record
                )
            ));
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
                    (payload ->> 'currentValue')::double precision,
                    (payload ->> 'targetValue')::double precision,
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
                        when changed_fields ? 'currentValue' then (payload ->> 'currentValue')::double precision
                        else current_value
                    end,
                    target_value = case
                        when changed_fields ? 'targetValue' then (payload ->> 'targetValue')::double precision
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
            jsonb_build_object('operationId', operation_id, 'revision', next_revision)
        );

        results := results || jsonb_build_array(jsonb_build_object(
            'operationId', operation_id,
            'status', 'accepted',
            'revision', next_revision,
            'cursor', change_cursor
        ));
    end loop;

    select coalesce(max(change.cursor), 0)
    into latest_cursor
    from public.change_log as change
    where change.workspace_id = p_workspace_id;

    insert into public.device_cursors (workspace_id, account_id, device_id, cursor, last_seen_at)
    values (p_workspace_id, account_id, p_device_id, latest_cursor, now())
    on conflict (workspace_id, account_id, device_id) do update
    set cursor = greatest(public.device_cursors.cursor, excluded.cursor),
        last_seen_at = excluded.last_seen_at;

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
begin
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
        'assets', coalesce((
            select jsonb_agg(private.entity_record(p_workspace_id, 'asset', asset.id) order by asset.created_at, asset.id)
            from public.assets as asset where asset.workspace_id = p_workspace_id
        ), '[]'::jsonb),
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
    account_id uuid := private.require_workspace_owner(p_workspace_id);
    erased_at timestamptz := clock_timestamp();
begin
    if p_workspace_id is distinct from p_confirm_workspace_id then
        raise exception using errcode = '22023', message = 'workspace erasure confirmation does not match';
    end if;

    delete from public.workspaces
    where id = p_workspace_id
      and owner_account_id = account_id;

    if not found then
        raise exception using errcode = '42501', message = 'workspace access denied';
    end if;

    return jsonb_build_object(
        'contractVersion', 1,
        'workspaceId', p_workspace_id,
        'erasedAt', erased_at
    );
end;
$$;

revoke all on function private.require_workspace_owner(uuid) from public, anon, authenticated;
revoke all on function private.entity_record(uuid, text, uuid) from public, anon, authenticated;
revoke all on function private.entity_field_writers(uuid, text, uuid) from public, anon, authenticated;
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
