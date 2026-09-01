begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(97);

select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'workspaces', 'workspaces table exists');
select has_table('public', 'workspace_members', 'workspace_members table exists');
select has_view('public', 'members', 'members compatibility view exists');
select has_table('public', 'moves', 'moves table exists');
select has_table('public', 'appearance', 'appearance table exists');
select has_table('public', 'primary_goals', 'primary_goals table exists');
select has_table('public', 'milestones', 'milestones table exists');
select has_table('public', 'assets', 'assets table exists');
select has_table('public', 'change_log', 'change_log table exists');
select has_table('public', 'device_cursors', 'device_cursors table exists');
select has_table('public', 'activity_events', 'activity_events table exists');
select has_table('private', 'sync_operation_receipts', 'immutable operation receipts exist');
select has_table('private', 'workspace_erasure_receipts', 'durable erasure tombstones exist');
select has_table('private', 'product_capabilities', 'external integration gates exist');
select has_table('private', 'workspace_asset_transfers', 'private-object transfer proofs exist');
select has_trigger(
    'auth',
    'users',
    'founder_office_guard_auth_user_delete_v1',
    'Auth identity deletion is blocked until product workspace erasure finishes'
);
select has_index(
    'public',
    'workspaces',
    'workspaces_one_per_owner_v1',
    'database enforces one workspace per owner'
);
select hasnt_column('public', 'profiles', 'email', 'profiles do not use email as a tenancy key');
select ok(
    not has_table_privilege('anon', 'public.workspaces', 'select'),
    'anonymous users cannot select workspaces'
);
select ok(
    not has_function_privilege(
        'anon',
        'public.bootstrap_workspace(uuid,uuid,text,text)',
        'execute'
    ),
    'anonymous users cannot execute bootstrap_workspace'
);
select ok(
    not exists (
        select 1
        from unnest(array[
            'profiles', 'workspaces', 'workspace_members', 'members', 'moves',
            'appearance', 'primary_goals', 'milestones', 'assets', 'change_log', 'device_cursors',
            'activity_events'
        ]) as target(table_name)
        where has_table_privilege('anon', 'public.' || target.table_name, 'select')
           or has_table_privilege('anon', 'public.' || target.table_name, 'insert')
           or has_table_privilege('anon', 'public.' || target.table_name, 'update')
           or has_table_privilege('anon', 'public.' || target.table_name, 'delete')
    ),
    'direct-write matrix: anon has no direct read or mutation privilege on product tables'
);
select ok(
    not exists (
        select 1
        from unnest(array[
            'profiles', 'workspaces', 'workspace_members', 'members', 'moves',
            'appearance', 'primary_goals', 'milestones', 'assets', 'change_log', 'device_cursors',
            'activity_events'
        ]) as target(table_name)
        where has_table_privilege('authenticated', 'public.' || target.table_name, 'insert')
           or has_table_privilege('authenticated', 'public.' || target.table_name, 'update')
           or has_table_privilege('authenticated', 'public.' || target.table_name, 'delete')
    ),
    'direct-write matrix: authenticated clients cannot mutate any product table directly'
);
select ok(
    (
        select bool_and(has_table_privilege('authenticated', 'public.' || target.table_name, 'select'))
        from unnest(array[
            'profiles', 'workspaces', 'workspace_members', 'members', 'moves',
            'appearance', 'primary_goals', 'milestones', 'assets', 'activity_events'
        ]) as target(table_name)
    )
    and not has_table_privilege('authenticated', 'public.change_log', 'select')
    and not has_table_privilege('authenticated', 'public.device_cursors', 'select')
    and not has_table_privilege('authenticated', 'private.sync_operation_receipts', 'select')
    and not has_table_privilege('authenticated', 'private.workspace_erasure_receipts', 'select')
    and not has_table_privilege('authenticated', 'private.product_capabilities', 'select')
    and not has_table_privilege('authenticated', 'private.workspace_asset_transfers', 'select'),
    'direct-read matrix: authenticated clients get RLS views but no internal receipt, feed, or cursor tables'
);
select ok(
    (
        select bool_and(has_function_privilege(
            'authenticated',
            target.signature,
            'execute'
        ))
        from unnest(array[
            'public.bootstrap_workspace(uuid,uuid,text,text)',
            'public.push_operations(uuid,uuid,jsonb)',
            'public.pull_changes(uuid,uuid,bigint,integer)',
            'public.export_workspace(uuid)',
            'public.erase_workspace(uuid,uuid)'
        ]) as target(signature)
    )
    and (
        select bool_and(not has_function_privilege('anon', target.signature, 'execute'))
        from unnest(array[
            'public.bootstrap_workspace(uuid,uuid,text,text)',
            'public.push_operations(uuid,uuid,jsonb)',
            'public.pull_changes(uuid,uuid,bigint,integer)',
            'public.export_workspace(uuid)',
            'public.erase_workspace(uuid,uuid)'
        ]) as target(signature)
    ),
    'RPC execute matrix: only authenticated clients can execute all five canonical RPCs'
);
select ok(
    (
        select bool_and(pg_catalog.pg_get_userbyid(routine.proowner) = 'postgres')
        from pg_catalog.pg_proc as routine
        join pg_catalog.pg_namespace as namespace on namespace.oid = routine.pronamespace
        where (namespace.nspname, routine.proname) in (
            ('public', 'bootstrap_workspace'),
            ('public', 'push_operations'),
            ('public', 'pull_changes'),
            ('public', 'export_workspace'),
            ('public', 'erase_workspace'),
            ('private', 'require_workspace_owner'),
            ('private', 'entity_record'),
            ('private', 'entity_field_writers'),
            ('private', 'is_workspace_owner'),
            ('private', 'guard_auth_user_product_delete_v1')
        )
          and routine.prosecdef
    ),
    'SECURITY DEFINER ownership matrix: every privileged boundary is owned by postgres'
);

set local role anon;
select throws_ok(
    $$ select count(*) from public.workspaces $$,
    '42501',
    'permission denied for table workspaces',
    'anonymous identity cannot query workspace state'
);
reset role;

insert into auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
) values
    (
        '00000000-0000-0000-0000-000000000000',
        '11111111-1111-4111-8111-111111111111',
        'authenticated',
        'authenticated',
        'owner@example.test',
        '',
        now(),
        '{"provider":"google","providers":["google"]}'::jsonb,
        '{}'::jsonb,
        now(),
        now()
    ),
    (
        '00000000-0000-0000-0000-000000000000',
        '22222222-2222-4222-8222-222222222222',
        'authenticated',
        'authenticated',
        'unrelated@example.test',
        '',
        now(),
        '{"provider":"apple","providers":["apple"]}'::jsonb,
        '{}'::jsonb,
        now(),
        now()
    );

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
set local request.jwt.claims =
    '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated","app_metadata":{"provider":"google"}}';

select throws_ok(
    $$
        select public.bootstrap_workspace(
            '11111111-aaaa-4aaa-8aaa-111111111111',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'Owner Office',
            null
        )
    $$,
    '22023',
    'display name is required for first bootstrap',
    'first bootstrap requires the reviewed onboarding display name'
);

do $test$
begin
    perform public.bootstrap_workspace(
        '11111111-aaaa-4aaa-8aaa-111111111111',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'Owner Office',
        'Owner Example'
    );
end;
$test$;

reset role;
insert into public.appearance (
    id, workspace_id, schema_version, preferences, revision, field_clocks,
    field_writers, writer_device_id, created_at, updated_at
) values (
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    1,
    '{}'::jsonb,
    1,
    jsonb_build_object('schemaVersion', now(), 'preferences', now()),
    jsonb_build_object(
        'schemaVersion', '11111111-aaaa-4aaa-8aaa-111111111111',
        'preferences', '11111111-aaaa-4aaa-8aaa-111111111111'
    ),
    '11111111-aaaa-4aaa-8aaa-111111111111',
    now(),
    now()
);
insert into public.primary_goals (
    id, workspace_id, title, metric, current_value, target_value, unit, due_on,
    revision, field_clocks, field_writers, writer_device_id, created_at, updated_at
) values (
    'ffffffff-ffff-4fff-8fff-ffffffffffff',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'Exact decimal goal',
    'MRR',
    3000.12345678,
    10000.87654321,
    'usd',
    '2026-10-30',
    1,
    jsonb_build_object('title', now(), 'metric', now(), 'currentValue', now(),
        'targetValue', now(), 'unit', now(), 'dueOn', now()),
    jsonb_build_object(
        'title', '11111111-aaaa-4aaa-8aaa-111111111111',
        'metric', '11111111-aaaa-4aaa-8aaa-111111111111',
        'currentValue', '11111111-aaaa-4aaa-8aaa-111111111111',
        'targetValue', '11111111-aaaa-4aaa-8aaa-111111111111',
        'unit', '11111111-aaaa-4aaa-8aaa-111111111111',
        'dueOn', '11111111-aaaa-4aaa-8aaa-111111111111'
    ),
    '11111111-aaaa-4aaa-8aaa-111111111111',
    now(),
    now()
);
insert into public.milestones (
    id, workspace_id, title, due_at, revision, field_clocks, field_writers,
    writer_device_id, created_at, updated_at
) values (
    '77777777-7777-4777-8777-777777777777',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'Launch Founder''s Office',
    '2026-10-30T10:00:00Z',
    1,
    jsonb_build_object('title', now(), 'dueAt', now(), 'createdAt', now()),
    jsonb_build_object(
        'title', '11111111-aaaa-4aaa-8aaa-111111111111',
        'dueAt', '11111111-aaaa-4aaa-8aaa-111111111111',
        'createdAt', '11111111-aaaa-4aaa-8aaa-111111111111'
    ),
    '11111111-aaaa-4aaa-8aaa-111111111111',
    now(),
    now()
);
insert into public.assets (
    id, workspace_id, kind, storage_path, content_type, byte_size, sha256,
    revision, field_clocks, field_writers, writer_device_id, created_at, updated_at
) values (
    '99999999-9999-4999-8999-999999999999',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'visionImage',
    'workspaces/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/vision-images/99999999-9999-4999-8999-999999999999.jpg',
    'image/jpeg',
    12,
    repeat('a', 64),
    1,
    jsonb_build_object('kind', now(), 'storagePath', now(), 'contentType', now(),
        'byteSize', now(), 'sha256', now()),
    jsonb_build_object(
        'kind', '11111111-aaaa-4aaa-8aaa-111111111111',
        'storagePath', '11111111-aaaa-4aaa-8aaa-111111111111',
        'contentType', '11111111-aaaa-4aaa-8aaa-111111111111',
        'byteSize', '11111111-aaaa-4aaa-8aaa-111111111111',
        'sha256', '11111111-aaaa-4aaa-8aaa-111111111111'
    ),
    '11111111-aaaa-4aaa-8aaa-111111111111',
    now(),
    now()
);
select throws_ok(
    $$
        insert into public.assets (
            id, workspace_id, kind, storage_path, content_type, byte_size, sha256,
            revision, field_clocks, field_writers, writer_device_id, created_at, updated_at
        ) values (
            '98989898-9898-4898-8898-989898989898',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'visionImage',
            'workspaces/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/vision-images/98989898-9898-4898-8898-989898989898.jpg',
            'image/jpeg',
            1,
            repeat('b', 64),
            1,
            '{}'::jsonb,
            '{}'::jsonb,
            '11111111-aaaa-4aaa-8aaa-111111111111',
            now(),
            now()
        )
    $$,
    '23514',
    null,
    'asset path constraint rejects a cross-workspace private object reference'
);

set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-4222-8222-222222222222';
set local request.jwt.claims =
    '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated","app_metadata":{"provider":"apple"}}';

do $test$
begin
    perform public.bootstrap_workspace(
        '22222222-bbbb-4bbb-8bbb-222222222222',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'Other Office',
        'Other Example'
    );
end;
$test$;

reset role;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
set local request.jwt.claims =
    '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated","app_metadata":{"provider":"google"}}';

select throws_ok(
    $$
        select public.push_operations(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            jsonb_build_array(jsonb_build_object(
                'contractVersion', 1,
                'operationId', '70000000-0000-4000-8000-000000000001',
                'entityType', 'move',
                'entityId', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
                'action', 'upsert',
                'baseRevision', 1,
                'changedFields', jsonb_build_array('dueOn'),
                'fieldClocks', jsonb_build_object('dueOn', clock_timestamp()),
                'payload', jsonb_build_object('dueOn', '2026-09-02 10:00:00'),
                'occurredAt', clock_timestamp()
            ))
        )
    $$,
    '22023',
    'Move dueOn must be canonical YYYY-MM-DD',
    'date-only Move deadlines reject timestamp-like PostgreSQL casts'
);
select throws_ok(
    $$
        select public.push_operations(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            jsonb_build_array(jsonb_build_object(
                'contractVersion', 1,
                'operationId', '70000000-0000-4000-8000-000000000002',
                'entityType', 'primaryGoal',
                'entityId', 'ffffffff-ffff-4fff-8fff-ffffffffffff',
                'action', 'upsert',
                'baseRevision', 1,
                'changedFields', jsonb_build_array('dueOn'),
                'fieldClocks', jsonb_build_object('dueOn', clock_timestamp()),
                'payload', jsonb_build_object('dueOn', '2026-10-30T00:00:00Z'),
                'occurredAt', clock_timestamp()
            ))
        )
    $$,
    '22023',
    'Primary goal dueOn must be canonical YYYY-MM-DD',
    'date-only primary-goal deadlines reject timestamp strings'
);

select is(
    (select display_name from public.profiles),
    'Owner Example',
    'bootstrap stores the reviewed display name'
);
select is(
    (select identity_provider from public.profiles),
    'google',
    'product identity provider is stored separately'
);
select throws_ok(
    $$
        select public.bootstrap_workspace(
            '11111111-aaaa-4aaa-8aaa-111111111111',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'Owner Office',
            repeat('x', 81)
        )
    $$,
    '22023',
    'display name is invalid',
    'bootstrap rejects an unreviewable overlong display name'
);
select throws_ok(
    $$
        select public.bootstrap_workspace(
            '11111111-aaaa-4aaa-8aaa-111111111111',
            'abababab-abab-4bab-8bab-abababababab',
            'Second Owner Office',
            'Owner Example'
        )
    $$,
    '23505',
    'account already owns a different workspace',
    'one workspace per owner is enforced at the bootstrap boundary'
);
select is(
    public.bootstrap_workspace(
        '11111111-aaaa-4aaa-8aaa-111111111111',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'Owner Office',
        U&'e\0301'
    ) ->> 'startingCursor',
    '0',
    'bootstrap requires a full pull from cursor zero'
);
select is(
    (select display_name from public.profiles),
    normalize(U&'e\0301', NFC),
    'bootstrap stores the display name in NFC form'
);
select is(
    octet_length((public.bootstrap_workspace(
        '11111111-aaaa-4aaa-8aaa-111111111111',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'Owner Office',
        repeat(chr(129504), 80)
    ) -> 'profile' ->> 'displayName')),
    320,
    'display-name boundary accepts 80 four-byte visible symbols'
);
select throws_ok(
    $$
        select public.bootstrap_workspace(
            '11111111-aaaa-4aaa-8aaa-111111111111',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'Owner Office',
            '---'
        )
    $$,
    '22023',
    'display name is invalid',
    'display-name boundary rejects punctuation-only input'
);
select throws_ok(
    $$
        select public.bootstrap_workspace(
            '11111111-aaaa-4aaa-8aaa-111111111111',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'Owner Office',
            U&'\0301'
        )
    $$,
    '22023',
    'display name is invalid',
    'display-name boundary rejects a combining mark without a letter, number, or symbol'
);
select throws_ok(
    $$
        select public.bootstrap_workspace(
            '11111111-aaaa-4aaa-8aaa-111111111111',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'Owner Office',
            E'Priya\nShah'
        )
    $$,
    '22023',
    'display name is invalid',
    'display-name boundary rejects controls and line breaks'
);
select throws_ok(
    format(
        $sql$
            select public.bootstrap_workspace(
                '11111111-aaaa-4aaa-8aaa-111111111111',
                'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                'Owner Office',
                %L
            )
        $sql$,
        'Priya' || chr(8238) || 'Shah'
    ),
    '22023',
    'display name is invalid',
    'display-name boundary rejects bidi controls'
);
select is(
    public.bootstrap_workspace(
        '11111111-aaaa-4aaa-8aaa-111111111111',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'Owner Office',
        chr(178)
    ) -> 'profile' ->> 'displayName',
    chr(178),
    'display-name boundary accepts a Unicode other-number scalar exactly like the client'
);
select is(
    (select count(*) from public.workspaces),
    1::bigint,
    'owner RLS exposes only the owner workspace'
);
select is(
    (select count(*) from public.members),
    1::bigint,
    'compatibility membership view preserves owner RLS'
);
select ok(
    not has_table_privilege('authenticated', 'public.moves', 'insert'),
    'authenticated users have no direct Move insert grant'
);

select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '10000000-0000-4000-8000-000000000001',
            'entityType', 'move',
            'entityId', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            'action', 'upsert',
            'baseRevision', 0,
            'changedFields', jsonb_build_array(
                'title', 'details', 'status', 'priority', 'source', 'createdAt'
            ),
            'fieldClocks', jsonb_build_object(
                'title', '2026-08-30T10:00:00Z',
                'details', '2026-08-30T10:00:00Z',
                'status', '2026-08-30T10:00:00Z',
                'priority', '2026-08-30T10:00:00Z',
                'source', '2026-08-30T10:00:00Z',
                'createdAt', '2026-08-30T10:00:00Z'
            ),
            'payload', jsonb_build_object(
                'title', 'Synthetic Move',
                'details', '',
                'status', 'next',
                'priority', 'P1',
                'source', 'policy-test',
                'createdAt', '2026-08-30T10:00:00Z'
            ),
            'occurredAt', '2026-08-30T10:00:00Z'
        ))
    ) -> 'results' -> 0 ->> 'status',
    'accepted',
    'owner can push a valid Move operation'
);
select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '10000000-0000-4000-8000-000000000001',
            'entityType', 'move',
            'entityId', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            'action', 'upsert',
            'baseRevision', 0,
            'changedFields', jsonb_build_array(
                'title', 'details', 'status', 'priority', 'source', 'createdAt'
            ),
            'fieldClocks', jsonb_build_object(
                'title', '2026-08-30T10:00:00Z',
                'details', '2026-08-30T10:00:00Z',
                'status', '2026-08-30T10:00:00Z',
                'priority', '2026-08-30T10:00:00Z',
                'source', '2026-08-30T10:00:00Z',
                'createdAt', '2026-08-30T10:00:00Z'
            ),
            'payload', jsonb_build_object(
                'title', 'Synthetic Move',
                'details', '',
                'status', 'next',
                'priority', 'P1',
                'source', 'policy-test',
                'createdAt', '2026-08-30T10:00:00Z'
            ),
            'occurredAt', '2026-08-30T10:00:00Z'
        ))
    ) -> 'results' -> 0 ->> 'status',
    'duplicate',
    'operation IDs make retries idempotent'
);
select throws_ok(
    $$
        select public.push_operations(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            jsonb_build_array(jsonb_build_object(
                'contractVersion', 1,
                'operationId', '10000000-0000-4000-8000-000000000001',
                'entityType', 'move',
                'entityId', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
                'action', 'upsert',
                'baseRevision', 0,
                'changedFields', jsonb_build_array(
                    'title', 'details', 'status', 'priority', 'source', 'createdAt'
                ),
                'fieldClocks', jsonb_build_object(
                    'title', '2026-08-30T10:00:00Z',
                    'details', '2026-08-30T10:00:00Z',
                    'status', '2026-08-30T10:00:00Z',
                    'priority', '2026-08-30T10:00:00Z',
                    'source', '2026-08-30T10:00:00Z',
                    'createdAt', '2026-08-30T10:00:00Z'
                ),
                'payload', jsonb_build_object(
                    'title', 'Different content',
                    'details', '',
                    'status', 'next',
                    'priority', 'P1',
                    'source', 'policy-test',
                    'createdAt', '2026-08-30T10:00:00Z'
                ),
                'occurredAt', '2026-08-30T10:00:00Z'
            ))
        )
    $$,
    '22023',
    'operation ID was reused with different content',
    'immutable operation IDs reject a retry with different content'
);
select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '60000000-0000-4000-8000-000000000001',
            'entityType', 'milestone',
            'entityId', '77777777-7777-4777-8777-777777777777',
            'action', 'upsert',
            'baseRevision', 1,
            'changedFields', jsonb_build_array('title'),
            'fieldClocks', jsonb_build_object('title', clock_timestamp()),
            'payload', jsonb_build_object('title', 'Launch Founder''s Office v1'),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 ->> 'status',
    'accepted',
    'milestone is a first-class sync entity'
);
select is(
    (select title from public.milestones where id = '77777777-7777-4777-8777-777777777777'),
    'Launch Founder''s Office v1',
    'milestone mutation preserves countdown history outside Appearance JSON'
);
select is(
    (select count(*) from public.moves),
    1::bigint,
    'owner can read the accepted Move through RLS'
);
select is(
    jsonb_build_array(
        (select count(*) from public.profiles),
        (select count(*) from public.workspaces),
        (select count(*) from public.workspace_members),
        (select count(*) from public.moves),
        (select count(*) from public.appearance),
        (select count(*) from public.primary_goals),
        (select count(*) from public.milestones),
        (select count(*) from public.assets),
        (select count(*) from public.activity_events)
    ),
    '[1,1,1,1,1,1,1,1,3]'::jsonb,
    'RLS read matrix: owner sees only their profile and every class of their workspace data'
);

reset role;
select is(
    (
        select cursor
        from public.device_cursors
        where workspace_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
          and account_id = '11111111-1111-4111-8111-111111111111'
          and device_id = '11111111-aaaa-4aaa-8aaa-111111111111'
    ),
    0::bigint,
    'push does not acknowledge unseen changes on behalf of a device'
);
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
set local request.jwt.claims =
    '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated","app_metadata":{"provider":"google"}}';
select is(
    jsonb_array_length(
        public.pull_changes(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            0,
            200
        ) -> 'changes'
    ),
    2,
    'pull_changes returns the ordered change feed'
);
select ok(
    public.pull_changes(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        0,
        200
    ) -> 'changes' -> 0 -> 'changedFields' ? 'title',
    'pull_changes exposes the changed-field mask'
);
select throws_ok(
    $$
        select public.pull_changes(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            999999999,
            200
        )
    $$,
    '22023',
    'pull cursor is ahead of the workspace feed',
    'cursor ahead of the workspace feed is rejected instead of acknowledged'
);
select is(
    jsonb_array_length(
        public.export_workspace('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') -> 'moves'
    ),
    1,
    'owner can export the workspace'
);
select is(
    public.export_workspace('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
        -> 'assetTransfer' ->> 'state',
    'requiresPrivateStorageAdapter',
    'export fails closed until the exact private-object manifest is externally verified'
);
select is(
    public.export_workspace('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
        -> 'primaryGoals' -> 0 ->> 'currentValue',
    '3000.12345678',
    'exact numeric(30,8) values survive the export contract without binary rounding'
);
select is(
    public.export_workspace('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
        -> 'milestones' -> 0 ->> 'title',
    'Launch Founder''s Office v1',
    'workspace export includes first-class milestone history'
);
select is(
    public.export_workspace('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
        -> 'assetTransfer' -> 'manifest' -> 0 ->> 'storagePath',
    'workspaces/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/vision-images/99999999-9999-4999-8999-999999999999.jpg',
    'private asset manifest uses the exact workspace and entity prefix'
);
select throws_ok(
    $$
        select public.push_operations(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            jsonb_build_array(jsonb_build_object(
                'contractVersion', 1,
                'operationId', '88888888-8888-4888-8888-888888888888',
                'entityType', 'asset',
                'entityId', '99999999-9999-4999-8999-999999999999',
                'action', 'upsert',
                'baseRevision', 1,
                'changedFields', jsonb_build_array('contentType'),
                'fieldClocks', jsonb_build_object('contentType', clock_timestamp()),
                'payload', jsonb_build_object('contentType', 'image/png'),
                'occurredAt', clock_timestamp()
            ))
        )
    $$,
    'PT503',
    'asset sync is disabled until private export and erasure are verified',
    'asset mutations fail closed until the private storage adapter gate passes'
);
select throws_ok(
    $$
        select public.erase_workspace(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        )
    $$,
    'PT503',
    'private asset deletion has not been verified for this workspace',
    'workspace erasure refuses to orphan unverified private asset bytes'
);

reset role;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-4222-8222-222222222222';
set local request.jwt.claims =
    '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated","app_metadata":{"provider":"apple"}}';

select is(
    (select count(*) from public.workspaces where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    0::bigint,
    'unrelated user cannot see the owner workspace'
);
select is(
    (select count(*) from public.moves),
    0::bigint,
    'unrelated user cannot see owner Moves'
);
select is(
    jsonb_build_array(
        (select count(*) from public.appearance),
        (select count(*) from public.primary_goals),
        (select count(*) from public.milestones),
        (select count(*) from public.assets)
    ),
    '[0,0,0,0]'::jsonb,
    'RLS read matrix: unrelated user cannot read any owner appearance, goal, milestone, or asset row'
);
select throws_ok(
    $$
        select public.push_operations(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '22222222-bbbb-4bbb-8bbb-222222222222',
            '[]'::jsonb
        )
    $$,
    '42501',
    'workspace access denied',
    'unrelated user cannot push to the owner workspace'
);
select throws_ok(
    $$ select public.export_workspace('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') $$,
    '42501',
    'workspace access denied',
    'unrelated user cannot export the owner workspace'
);

reset role;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
set local request.jwt.claims =
    '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated","app_metadata":{"provider":"google"}}';

select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '10000000-0000-4000-8000-000000000002',
            'entityType', 'move',
            'entityId', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            'action', 'upsert',
            'baseRevision', 1,
            'changedFields', jsonb_build_array('dueOn'),
            'fieldClocks', jsonb_build_object('dueOn', clock_timestamp()),
            'payload', jsonb_build_object('dueOn', '2026-09-02'),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 ->> 'status',
    'accepted',
    'server accepts the first field edit'
);
select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '10000000-0000-4000-8000-000000000003',
            'entityType', 'move',
            'entityId', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            'action', 'upsert',
            'baseRevision', 1,
            'changedFields', jsonb_build_array('priority'),
            'fieldClocks', jsonb_build_object('priority', clock_timestamp()),
            'payload', jsonb_build_object('priority', 'P0'),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 ->> 'status',
    'accepted',
    'stale disjoint field edit merges without losing the server field'
);
select is(
    (select due_on::text from public.moves where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
    '2026-09-02',
    'disjoint merge preserves the newer deadline'
);
select is(
    (select priority from public.moves where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
    'P0',
    'disjoint merge applies the priority edit'
);

select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '20000000-0000-4000-8000-000000000001',
            'entityType', 'move',
            'entityId', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            'action', 'upsert',
            'baseRevision', 0,
            'changedFields', jsonb_build_array(
                'title', 'details', 'status', 'priority', 'source', 'createdAt'
            ),
            'fieldClocks', jsonb_build_object(
                'title', clock_timestamp(),
                'details', clock_timestamp(),
                'status', clock_timestamp(),
                'priority', clock_timestamp(),
                'source', clock_timestamp(),
                'createdAt', clock_timestamp()
            ),
            'payload', jsonb_build_object(
                'title', 'Conflict fixture',
                'details', '',
                'status', 'next',
                'priority', 'P2',
                'source', 'policy-test',
                'createdAt', clock_timestamp()
            ),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 ->> 'status',
    'accepted',
    'same-field conflict fixture is created'
);
select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '20000000-0000-4000-8000-000000000002',
            'entityType', 'move',
            'entityId', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            'action', 'upsert',
            'baseRevision', 1,
            'changedFields', jsonb_build_array('priority'),
            'fieldClocks', jsonb_build_object('priority', clock_timestamp()),
            'payload', jsonb_build_object('priority', 'P1'),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 ->> 'status',
    'accepted',
    'server applies the first same-field edit'
);
select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '20000000-0000-4000-8000-000000000003',
            'entityType', 'move',
            'entityId', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            'action', 'upsert',
            'baseRevision', 1,
            'changedFields', jsonb_build_array('priority'),
            'fieldClocks', jsonb_build_object('priority', clock_timestamp() + interval '1 minute'),
            'payload', jsonb_build_object('priority', 'P0'),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 ->> 'status',
    'conflict',
    'stale same-field edit conflicts even when its clock is later'
);
select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '20000000-0000-4000-8000-000000000004',
            'entityType', 'move',
            'entityId', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            'action', 'upsert',
            'baseRevision', 1,
            'changedFields', jsonb_build_array('priority'),
            'fieldClocks', jsonb_build_object('priority', clock_timestamp() + interval '1 minute'),
            'payload', jsonb_build_object('priority', 'P0'),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 -> 'conflict' ->> 'reason',
    'overlappingChanges',
    'same-field conflict explains the overlapping change'
);
select is(
    public.push_operations(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '11111111-aaaa-4aaa-8aaa-111111111111',
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '20000000-0000-4000-8000-000000000005',
            'entityType', 'move',
            'entityId', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            'action', 'upsert',
            'baseRevision', 1,
            'changedFields', jsonb_build_array('priority'),
            'fieldClocks', jsonb_build_object('priority', clock_timestamp() + interval '1 minute'),
            'payload', jsonb_build_object('priority', 'P0'),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 -> 'conflict' -> 'conflictingFields' ->> 0,
    'priority',
    'conflict response names only a field backed by the server field-clock map'
);
select throws_ok(
    $$
        select public.push_operations(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            '[{
                "contractVersion":1,
                "operationId":"20000000-0000-4000-8000-000000000006",
                "entityType":"move",
                "entityId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                "action":"upsert",
                "baseRevision":2,
                "changedFields":["priority"],
                "fieldClocks":{"priority":"2026-08-31 10:00:00+00"},
                "payload":{"priority":"P0"},
                "occurredAt":"2026-08-31T10:00:00Z"
            }]'::jsonb
        )
    $$,
    '22023',
    'field clock is invalid',
    'field clocks reject PostgreSQL timestamp aliases outside canonical RFC 3339'
);
select throws_ok(
    format(
        $sql$
            select public.push_operations(
                'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                '11111111-aaaa-4aaa-8aaa-111111111111',
                %L::jsonb
            )
        $sql$,
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '30000000-0000-4000-8000-000000000001',
            'entityType', 'move',
            'entityId', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            'action', 'upsert',
            'baseRevision', 3,
            'changedFields', jsonb_build_array('priority'),
            'fieldClocks', jsonb_build_object('priority', clock_timestamp() + interval '10 minutes'),
            'payload', jsonb_build_object('priority', 'P3'),
            'occurredAt', clock_timestamp()
        ))::text
    ),
    '22023',
    'operation clock is too far in the future',
    'clock-skew gate rejects operations more than five minutes ahead'
);
select throws_ok(
    format(
        $sql$
            select public.push_operations(
                'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                '11111111-aaaa-4aaa-8aaa-111111111111',
                %L::jsonb
            )
        $sql$,
        jsonb_build_array(jsonb_build_object(
            'contractVersion', 1,
            'operationId', '30000000-0000-4000-8000-000000000002',
            'entityType', 'move',
            'entityId', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            'action', 'upsert',
            'baseRevision', 3,
            'changedFields', jsonb_build_array('priority'),
            'fieldClocks', jsonb_build_object('priority', clock_timestamp()),
            'payload', jsonb_build_object('priority', 'P3'),
            'occurredAt', clock_timestamp() + interval '10 minutes'
        ))::text
    ),
    '22023',
    'operation clock is too far in the future',
    'clock-skew gate independently rejects a future occurredAt value'
);
select throws_ok(
    $$
        select public.push_operations(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            '[{
                "contractVersion":"1",
                "operationId":"30000000-0000-4000-8000-000000000003",
                "entityType":"move",
                "entityId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                "action":"upsert",
                "baseRevision":3,
                "changedFields":["priority"],
                "fieldClocks":{"priority":"2026-08-31T10:00:00Z"},
                "payload":{"priority":"P3"},
                "occurredAt":"2026-08-31T10:00:00Z"
            }]'::jsonb
        )
    $$,
    '22023',
    'operation scalar types are invalid',
    'SQL trust boundary rejects a string where the schema requires an integer'
);
select throws_ok(
    $$
        select public.push_operations(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            jsonb_build_array(jsonb_build_object(
                'contractVersion', 1,
                'operationId', '30000000-0000-4000-8000-000000000004',
                'entityType', 'primaryGoal',
                'entityId', 'ffffffff-ffff-4fff-8fff-ffffffffffff',
                'action', 'upsert',
                'baseRevision', 1,
                'changedFields', jsonb_build_array('currentValue'),
                'fieldClocks', jsonb_build_object('currentValue', clock_timestamp()),
                'payload', jsonb_build_object('currentValue', 1.123456789),
                'occurredAt', clock_timestamp()
            ))
        )
    $$,
    '22023',
    'Primary goal value exceeds numeric(30,8)',
    'SQL trust boundary rejects decimals that exceed the exact eight-place contract'
);
select throws_ok(
    $$
        select public.erase_workspace(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        )
    $$,
    '22023',
    'workspace erasure confirmation does not match',
    'erase requires exact workspace-ID confirmation'
);
select is(
    (select count(*) from public.activity_events where kind = 'move.upserted'),
    5::bigint,
    'accepted mutations append content-free activity events only'
);
select is(
    (select count(*) from public.activity_events where metadata <> '{}'::jsonb),
    0::bigint,
    'activity history enforces an exact content-free metadata allow-list'
);
select is(
    (select count(*) from public.change_log where changed_fields && array['priority']),
    4::bigint,
    'change log persists changed fields for conflict detection'
);

reset role;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-4222-8222-222222222222';
set local request.jwt.claims =
    '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated","app_metadata":{"provider":"apple"}}';

select is(
    public.erase_workspace(
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    ) ->> 'workspaceId',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'owner can erase their own workspace'
);
select is(
    public.erase_workspace(
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    ) ->> 'erasedAt',
    public.erase_workspace(
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    ) ->> 'erasedAt',
    'erasure retry is idempotent and returns the original durable receipt'
);
select is(
    (select count(*) from public.workspaces),
    0::bigint,
    'erased workspace is no longer visible to its owner'
);
select throws_ok(
    $$
        select public.bootstrap_workspace(
            '22222222-bbbb-4bbb-8bbb-222222222222',
            'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            'Resurrected Office',
            'Other Example'
        )
    $$,
    '22023',
    'workspace was permanently erased',
    'erased workspace cannot be resurrected by a stale local snapshot'
);

reset role;
delete from auth.users where id = '22222222-2222-4222-8222-222222222222';

select is(
    (
        select count(*)
        from private.workspace_erasure_receipts
        where workspace_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
          and owner_account_id is null
    ),
    1::bigint,
    'account deletion removes the user link but preserves the non-resurrection tombstone'
);
select is(
    (select count(*) from public.profiles where id = '22222222-2222-4222-8222-222222222222'),
    0::bigint,
    'safe account deletion removes the profile after workspace erasure'
);

set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-4222-8222-222222222222';
set local request.jwt.claims =
    '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated","app_metadata":{"provider":"apple"}}';

select is(
    (select count(*) from public.profiles where id = '22222222-2222-4222-8222-222222222222'),
    0::bigint,
    'a stale token for a deleted account cannot read a profile'
);
select throws_ok(
    $$
        select public.bootstrap_workspace(
            '22222222-bbbb-4bbb-8bbb-222222222222',
            'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            'Deleted account workspace',
            'Deleted Account'
        )
    $$,
    '23503',
    null,
    'a deleted account cannot recreate product state with a stale token'
);

reset role;
select throws_ok(
    $$ delete from auth.users where id = '11111111-1111-4111-8111-111111111111' $$,
    'PT409',
    'erase the product workspace before deleting the Auth identity',
    'account deletion cannot bypass workspace asset export and erasure gates'
);
select is(
    (select count(*) from public.workspaces where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    1::bigint,
    'blocked account deletion leaves canonical workspace data intact'
);

select * from finish();
rollback;
