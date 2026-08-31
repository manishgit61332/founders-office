begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(50);

select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'workspaces', 'workspaces table exists');
select has_table('public', 'workspace_members', 'workspace_members table exists');
select has_view('public', 'members', 'members compatibility view exists');
select has_table('public', 'moves', 'moves table exists');
select has_table('public', 'appearance', 'appearance table exists');
select has_table('public', 'primary_goals', 'primary_goals table exists');
select has_table('public', 'assets', 'assets table exists');
select has_table('public', 'change_log', 'change_log table exists');
select has_table('public', 'device_cursors', 'device_cursors table exists');
select has_table('public', 'activity_events', 'activity_events table exists');
select col_not_exists('public', 'profiles', 'email', 'profiles do not use email as a tenancy key');
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
            repeat('x', 121)
        )
    $$,
    '22023',
    'display name is invalid',
    'bootstrap rejects an unreviewable overlong display name'
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
                'title', clock_timestamp(),
                'details', clock_timestamp(),
                'status', clock_timestamp(),
                'priority', clock_timestamp(),
                'source', clock_timestamp(),
                'createdAt', clock_timestamp()
            ),
            'payload', jsonb_build_object(
                'title', 'Synthetic Move',
                'details', '',
                'status', 'next',
                'priority', 'P1',
                'source', 'policy-test',
                'createdAt', clock_timestamp()
            ),
            'occurredAt', clock_timestamp()
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
                'title', clock_timestamp(),
                'details', clock_timestamp(),
                'status', clock_timestamp(),
                'priority', clock_timestamp(),
                'source', clock_timestamp(),
                'createdAt', clock_timestamp()
            ),
            'payload', jsonb_build_object(
                'title', 'Ignored retry',
                'details', '',
                'status', 'next',
                'priority', 'P3',
                'source', 'policy-test',
                'createdAt', clock_timestamp()
            ),
            'occurredAt', clock_timestamp()
        ))
    ) -> 'results' -> 0 ->> 'status',
    'duplicate',
    'operation IDs make retries idempotent'
);
select is(
    (select count(*) from public.moves),
    1::bigint,
    'owner can read the accepted Move through RLS'
);
select is(
    jsonb_array_length(
        public.pull_changes(
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '11111111-aaaa-4aaa-8aaa-111111111111',
            0,
            200
        ) -> 'changes'
    ),
    1,
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
select is(
    jsonb_array_length(
        public.export_workspace('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') -> 'moves'
    ),
    1,
    'owner can export the workspace'
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
    (select count(*) from public.workspaces),
    0::bigint,
    'erased workspace is no longer visible to its owner'
);

reset role;
delete from auth.users where id = '11111111-1111-4111-8111-111111111111';

select is(
    (
        select count(*)
        from public.workspaces
        where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    ),
    0::bigint,
    'deleting an Auth account cascades its profile and owned workspace'
);

set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
set local request.jwt.claims =
    '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated","app_metadata":{"provider":"google"}}';

select is(
    (select count(*) from public.profiles),
    0::bigint,
    'a stale token for a deleted account cannot read a profile'
);
select throws_ok(
    $$
        select public.bootstrap_workspace(
            '11111111-aaaa-4aaa-8aaa-111111111111',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'Deleted account workspace',
            'Deleted Account'
        )
    $$,
    '23503',
    null,
    'a deleted account cannot recreate product state with a stale token'
);

select * from finish();
rollback;
