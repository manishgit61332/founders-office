begin;

create schema if not exists private;

create table public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    identity_provider text not null,
    display_name text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint profiles_identity_provider_v1 check (identity_provider in ('google', 'apple')),
    constraint profiles_display_name_length check (
        display_name is null or char_length(btrim(display_name)) between 1 and 120
    ),
    constraint profiles_updated_after_created check (updated_at >= created_at)
);

comment on table public.profiles is
    'Opaque Founder account rows keyed by auth user UUID. No email or display name is a tenancy key.';

create table public.workspaces (
    id uuid primary key default gen_random_uuid(),
    owner_account_id uuid not null references public.profiles(id) on delete cascade,
    name text not null default 'Founder''s Office',
    contract_version integer not null default 1,
    revision bigint not null default 1,
    field_clocks jsonb not null default '{}'::jsonb,
    field_writers jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint workspaces_name_length check (char_length(btrim(name)) between 1 and 120),
    constraint workspaces_contract_v1 check (contract_version = 1),
    constraint workspaces_revision_positive check (revision > 0),
    constraint workspaces_field_clocks_object check (jsonb_typeof(field_clocks) = 'object'),
    constraint workspaces_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint workspaces_updated_after_created check (updated_at >= created_at)
);

create index workspaces_owner_account_idx on public.workspaces(owner_account_id);

create table public.workspace_members (
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    account_id uuid not null references public.profiles(id) on delete cascade,
    role text not null default 'owner',
    created_at timestamptz not null default now(),
    primary key (workspace_id, account_id),
    constraint workspace_members_single_owner_role_v1 check (role = 'owner'),
    constraint workspace_members_one_account_per_workspace_v1 unique (workspace_id)
);

comment on table public.workspace_members is
    'Single-owner v1 membership. A future collaboration contract must replace the v1 uniqueness and role constraint explicitly.';

create index workspace_members_account_idx on public.workspace_members(account_id);

create table public.moves (
    id uuid primary key,
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    title text not null,
    details text not null default '',
    status text not null,
    previous_status text,
    priority text not null,
    due_on date,
    completed_at timestamptz,
    deleted_at timestamptz,
    source text not null,
    revision bigint not null,
    field_clocks jsonb not null,
    field_writers jsonb not null,
    writer_device_id uuid not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    constraint moves_title_length check (char_length(btrim(title)) between 1 and 500),
    constraint moves_details_length check (char_length(details) <= 20000),
    constraint moves_status_v1 check (status in ('doing', 'next', 'blocked', 'done')),
    constraint moves_previous_status_v1 check (
        previous_status is null or previous_status in ('doing', 'next', 'blocked', 'done')
    ),
    constraint moves_priority_v1 check (priority in ('P0', 'P1', 'P2', 'P3')),
    constraint moves_source_length check (char_length(btrim(source)) between 1 and 64),
    constraint moves_revision_positive check (revision > 0),
    constraint moves_field_clocks_object check (jsonb_typeof(field_clocks) = 'object'),
    constraint moves_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint moves_updated_after_created check (updated_at >= created_at),
    constraint moves_workspace_entity_unique unique (workspace_id, id)
);

create index moves_workspace_updated_idx on public.moves(workspace_id, updated_at, id);
create index moves_workspace_active_idx on public.moves(workspace_id, status, due_on)
    where deleted_at is null;

create table public.appearance (
    id uuid primary key,
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    schema_version integer not null,
    preferences jsonb not null,
    deleted_at timestamptz,
    revision bigint not null,
    field_clocks jsonb not null,
    field_writers jsonb not null,
    writer_device_id uuid not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    constraint appearance_one_record_per_workspace_v1 unique (workspace_id),
    constraint appearance_schema_positive check (schema_version > 0),
    constraint appearance_preferences_object check (jsonb_typeof(preferences) = 'object'),
    constraint appearance_revision_positive check (revision > 0),
    constraint appearance_field_clocks_object check (jsonb_typeof(field_clocks) = 'object'),
    constraint appearance_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint appearance_updated_after_created check (updated_at >= created_at),
    constraint appearance_workspace_entity_unique unique (workspace_id, id)
);

create table public.primary_goals (
    id uuid primary key,
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    title text not null,
    metric text not null default '',
    current_value double precision,
    target_value double precision,
    unit text not null,
    due_on date not null,
    deleted_at timestamptz,
    revision bigint not null,
    field_clocks jsonb not null,
    field_writers jsonb not null,
    writer_device_id uuid not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    constraint primary_goals_title_length check (char_length(btrim(title)) between 1 and 500),
    constraint primary_goals_metric_length check (char_length(metric) <= 120),
    constraint primary_goals_unit_v1 check (unit in ('usd', 'inr', 'number', 'percent')),
    constraint primary_goals_revision_positive check (revision > 0),
    constraint primary_goals_field_clocks_object check (jsonb_typeof(field_clocks) = 'object'),
    constraint primary_goals_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint primary_goals_updated_after_created check (updated_at >= created_at),
    constraint primary_goals_workspace_entity_unique unique (workspace_id, id)
);

create unique index primary_goals_one_live_per_workspace_v1
    on public.primary_goals(workspace_id)
    where deleted_at is null;

create table public.assets (
    id uuid primary key,
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    kind text not null,
    storage_path text not null,
    content_type text not null,
    byte_size bigint not null,
    sha256 text not null,
    deleted_at timestamptz,
    revision bigint not null,
    field_clocks jsonb not null,
    field_writers jsonb not null,
    writer_device_id uuid not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    constraint assets_kind_v1 check (kind = 'visionImage'),
    constraint assets_storage_path_length check (char_length(storage_path) between 1 and 1024),
    constraint assets_content_type_length check (char_length(content_type) between 1 and 255),
    constraint assets_byte_size_v1 check (byte_size between 0 and 52428800),
    constraint assets_sha256 check (sha256 ~ '^[a-f0-9]{64}$'),
    constraint assets_revision_positive check (revision > 0),
    constraint assets_field_clocks_object check (jsonb_typeof(field_clocks) = 'object'),
    constraint assets_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint assets_updated_after_created check (updated_at >= created_at),
    constraint assets_workspace_path_unique unique (workspace_id, storage_path),
    constraint assets_workspace_entity_unique unique (workspace_id, id)
);

create table public.change_log (
    cursor bigint generated always as identity primary key,
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    operation_id uuid not null,
    entity_type text not null,
    entity_id uuid not null,
    action text not null,
    revision bigint not null,
    changed_fields text[] not null,
    record jsonb,
    actor_account_id uuid not null references public.profiles(id) on delete cascade,
    device_id uuid not null,
    changed_at timestamptz not null default now(),
    constraint change_log_entity_v1 check (
        entity_type in ('workspace', 'move', 'appearance', 'primaryGoal', 'asset')
    ),
    constraint change_log_action_v1 check (action in ('upsert', 'delete')),
    constraint change_log_revision_positive check (revision > 0),
    constraint change_log_changed_fields_count check (cardinality(changed_fields) between 1 and 32),
    constraint change_log_record_object check (record is null or jsonb_typeof(record) = 'object'),
    constraint change_log_operation_idempotency unique (workspace_id, operation_id)
);

create index change_log_workspace_cursor_idx on public.change_log(workspace_id, cursor);
create index change_log_workspace_entity_idx
    on public.change_log(workspace_id, entity_type, entity_id, cursor desc);

create table public.device_cursors (
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    account_id uuid not null references public.profiles(id) on delete cascade,
    device_id uuid not null,
    cursor bigint not null default 0,
    last_seen_at timestamptz not null default now(),
    primary key (workspace_id, account_id, device_id),
    constraint device_cursors_nonnegative check (cursor >= 0)
);

create table public.activity_events (
    sequence bigint generated always as identity unique,
    id uuid primary key default gen_random_uuid(),
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    actor_account_id uuid not null references public.profiles(id) on delete cascade,
    device_id uuid,
    operation_id uuid,
    kind text not null,
    entity_type text,
    entity_id uuid,
    occurred_at timestamptz not null default now(),
    metadata jsonb not null default '{}'::jsonb,
    constraint activity_events_kind_format check (
        char_length(kind) between 3 and 100
        and kind ~ '^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$'
    ),
    constraint activity_events_entity_v1 check (
        entity_type is null
        or entity_type in ('workspace', 'move', 'appearance', 'primaryGoal', 'asset')
    ),
    constraint activity_events_entity_pair check (
        (entity_type is null and entity_id is null)
        or (entity_type is not null and entity_id is not null)
    ),
    constraint activity_events_metadata_object check (jsonb_typeof(metadata) = 'object'),
    constraint activity_events_metadata_no_content check (
        not metadata ?| array[
            'title', 'details', 'email', 'name', 'path', 'token', 'prompt', 'message', 'content'
        ]
    ),
    constraint activity_events_operation_unique unique (workspace_id, operation_id)
);

comment on table public.activity_events is
    'User-owned durable activity history. Metadata is intentionally content-free and is not a diagnostic or analytics log.';

create index activity_events_workspace_sequence_idx
    on public.activity_events(workspace_id, sequence);

create or replace function private.is_workspace_owner(target_workspace_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.workspace_members as membership
        where membership.workspace_id = target_workspace_id
          and membership.account_id = auth.uid()
          and membership.role = 'owner'
    );
$$;

revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;
revoke all on function private.is_workspace_owner(uuid) from public, anon, authenticated;
grant execute on function private.is_workspace_owner(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.profiles force row level security;
alter table public.workspaces enable row level security;
alter table public.workspaces force row level security;
alter table public.workspace_members enable row level security;
alter table public.workspace_members force row level security;
alter table public.moves enable row level security;
alter table public.moves force row level security;
alter table public.appearance enable row level security;
alter table public.appearance force row level security;
alter table public.primary_goals enable row level security;
alter table public.primary_goals force row level security;
alter table public.assets enable row level security;
alter table public.assets force row level security;
alter table public.change_log enable row level security;
alter table public.change_log force row level security;
alter table public.device_cursors enable row level security;
alter table public.device_cursors force row level security;
alter table public.activity_events enable row level security;
alter table public.activity_events force row level security;

create policy profiles_owner_select_v1 on public.profiles
    for select to authenticated
    using (id = auth.uid());

create policy workspaces_owner_select_v1 on public.workspaces
    for select to authenticated
    using (owner_account_id = auth.uid() and private.is_workspace_owner(id));

create policy workspace_members_owner_select_v1 on public.workspace_members
    for select to authenticated
    using (account_id = auth.uid() and role = 'owner');

create policy moves_owner_select_v1 on public.moves
    for select to authenticated
    using (private.is_workspace_owner(workspace_id));

create policy appearance_owner_select_v1 on public.appearance
    for select to authenticated
    using (private.is_workspace_owner(workspace_id));

create policy primary_goals_owner_select_v1 on public.primary_goals
    for select to authenticated
    using (private.is_workspace_owner(workspace_id));

create policy assets_owner_select_v1 on public.assets
    for select to authenticated
    using (private.is_workspace_owner(workspace_id));

create policy change_log_owner_select_v1 on public.change_log
    for select to authenticated
    using (private.is_workspace_owner(workspace_id));

create policy device_cursors_owner_select_v1 on public.device_cursors
    for select to authenticated
    using (account_id = auth.uid() and private.is_workspace_owner(workspace_id));

create policy activity_events_owner_select_v1 on public.activity_events
    for select to authenticated
    using (private.is_workspace_owner(workspace_id));

create view public.members
with (security_invoker = true)
as
select workspace_id, account_id, role, created_at
from public.workspace_members;

comment on view public.members is
    'Read-only compatibility name for early v1 contract drafts. The authoritative table is workspace_members.';

revoke all on table
    public.profiles,
    public.workspaces,
    public.workspace_members,
    public.members,
    public.moves,
    public.appearance,
    public.primary_goals,
    public.assets,
    public.change_log,
    public.device_cursors,
    public.activity_events
from public, anon, authenticated;

revoke all on sequence
    public.change_log_cursor_seq,
    public.activity_events_sequence_seq
from public, anon, authenticated;

grant select on table
    public.profiles,
    public.workspaces,
    public.workspace_members,
    public.members,
    public.moves,
    public.appearance,
    public.primary_goals,
    public.assets,
    public.activity_events
to authenticated;

commit;
