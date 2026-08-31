begin;

create schema if not exists private;

create or replace function private.normalize_display_name_v1(candidate text)
returns text
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
    normalized text := normalize(candidate, NFC);
    first_scalar integer := 1;
    last_scalar integer := char_length(normalized);
    whitespace_ranges constant int4multirange :=
        '{[9,14),[32,33),[133,134),[160,161),[5760,5761),[8192,8204),[8232,8234),[8239,8240),[8287,8288),[12288,12289)}'::int4multirange;
begin
    while first_scalar <= last_scalar
          and ascii(substring(normalized from first_scalar for 1)) <@ whitespace_ranges loop
        first_scalar := first_scalar + 1;
    end loop;
    while last_scalar >= first_scalar
          and ascii(substring(normalized from last_scalar for 1)) <@ whitespace_ranges loop
        last_scalar := last_scalar - 1;
    end loop;
    return substring(normalized from first_scalar for last_scalar - first_scalar + 1);
end;
$$;

create or replace function private.is_valid_display_name_v1(candidate text)
returns boolean
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
    nfc_candidate text := normalize(candidate, NFC);
    clean_candidate text := private.normalize_display_name_v1(candidate);
    codepoint integer;
    symbol_ranges constant int4multirange :=
        '{[36,37),[43,44),[60,63),[94,95),[96,97),[124,125),[126,127),[162,167),[168,170),[172,173),[174,178),[180,181),[184,185),[215,216),[247,248),[706,710),[722,736),[741,748),[749,750),[751,768),[885,886),[900,902),[1014,1015),[1154,1155),[1421,1424),[1542,1545),[1547,1548),[1550,1552),[1758,1759),[1769,1770),[1789,1791),[2038,2039),[2046,2048),[2184,2185),[2546,2548),[2554,2556),[2801,2802),[2928,2929),[3059,3067),[3199,3200),[3407,3408),[3449,3450),[3647,3648),[3841,3844),[3859,3860),[3861,3864),[3866,3872),[3892,3893),[3894,3895),[3896,3897),[4030,4038),[4039,4045),[4046,4048),[4053,4057),[4254,4256),[5008,5018),[5741,5742),[6107,6108),[6464,6465),[6622,6656),[7009,7019),[7028,7037),[8125,8126),[8127,8130),[8141,8144),[8157,8160),[8173,8176),[8189,8191),[8260,8261),[8274,8275),[8314,8317),[8330,8333),[8352,8385),[8448,8450),[8451,8455),[8456,8458),[8468,8469),[8470,8473),[8478,8484),[8485,8486),[8487,8488),[8489,8490),[8494,8495),[8506,8508),[8512,8517),[8522,8526),[8527,8528),[8586,8588),[8592,8968),[8972,9001),[9003,9258),[9280,9291),[9372,9450),[9472,10088),[10132,10181),[10183,10214),[10224,10627),[10649,10712),[10716,10748),[10750,11124),[11126,11158),[11159,11264),[11493,11499),[11856,11858),[11904,11930),[11931,12020),[12032,12246),[12272,12288),[12292,12293),[12306,12308),[12320,12321),[12342,12344),[12350,12352),[12443,12445),[12688,12690),[12694,12704),[12736,12774),[12783,12784),[12800,12831),[12842,12872),[12880,12881),[12896,12928),[12938,12977),[12992,13312),[19904,19968),[42128,42183),[42752,42775),[42784,42786),[42889,42891),[43048,43052),[43062,43066),[43639,43642),[43867,43868),[43882,43884),[64297,64298),[64434,64451),[64832,64848),[64975,64976),[65020,65024),[65122,65123),[65124,65127),[65129,65130),[65284,65285),[65291,65292),[65308,65311),[65342,65343),[65344,65345),[65372,65373),[65374,65375),[65504,65511),[65512,65519),[65532,65534),[65847,65856),[65913,65930),[65932,65935),[65936,65949),[65952,65953),[66000,66045),[67703,67705),[68296,68297),[69006,69008),[71487,71488),[73685,73714),[92988,92992),[92997,92998),[113820,113821),[117760,118000),[118016,118452),[118608,118724),[118784,119030),[119040,119079),[119081,119141),[119146,119149),[119171,119173),[119180,119210),[119214,119275),[119296,119362),[119365,119366),[119552,119639),[120513,120514),[120539,120540),[120571,120572),[120597,120598),[120629,120630),[120655,120656),[120687,120688),[120713,120714),[120745,120746),[120771,120772),[120832,121344),[121399,121403),[121453,121461),[121462,121476),[121477,121479),[123215,123216),[123647,123648),[126124,126125),[126128,126129),[126254,126255),[126704,126706),[126976,127020),[127024,127124),[127136,127151),[127153,127168),[127169,127184),[127185,127222),[127245,127406),[127462,127491),[127504,127548),[127552,127561),[127568,127570),[127584,127590),[127744,128728),[128732,128749),[128752,128765),[128768,128887),[128891,128986),[128992,129004),[129008,129009),[129024,129036),[129040,129096),[129104,129114),[129120,129160),[129168,129198),[129200,129212),[129216,129218),[129280,129620),[129632,129646),[129648,129661),[129664,129674),[129679,129735),[129742,129757),[129759,129770),[129776,129785),[129792,129939),[129940,130032)}'::int4multirange;
    number_ranges constant int4multirange :=
        '{[48,58),[178,180),[185,186),[188,191),[1632,1642),[1776,1786),[1984,1994),[2406,2416),[2534,2544),[2548,2554),[2662,2672),[2790,2800),[2918,2928),[2930,2936),[3046,3059),[3174,3184),[3192,3199),[3302,3312),[3416,3423),[3430,3449),[3558,3568),[3664,3674),[3792,3802),[3872,3892),[4160,4170),[4240,4250),[4969,4989),[5870,5873),[6112,6122),[6128,6138),[6160,6170),[6470,6480),[6608,6619),[6784,6794),[6800,6810),[6992,7002),[7088,7098),[7232,7242),[7248,7258),[8304,8305),[8308,8314),[8320,8330),[8528,8579),[8581,8586),[9312,9372),[9450,9472),[10102,10132),[11517,11518),[12295,12296),[12321,12330),[12344,12347),[12690,12694),[12832,12842),[12872,12880),[12881,12896),[12928,12938),[12977,12992),[42528,42538),[42726,42736),[43056,43062),[43216,43226),[43264,43274),[43472,43482),[43504,43514),[43600,43610),[44016,44026),[65296,65306),[65799,65844),[65856,65913),[65930,65932),[66273,66300),[66336,66340),[66369,66370),[66378,66379),[66513,66518),[66720,66730),[67672,67680),[67705,67712),[67751,67760),[67835,67840),[67862,67868),[68028,68030),[68032,68048),[68050,68096),[68160,68169),[68221,68223),[68253,68256),[68331,68336),[68440,68448),[68472,68480),[68521,68528),[68858,68864),[68912,68922),[68928,68938),[69216,69247),[69405,69415),[69457,69461),[69573,69580),[69714,69744),[69872,69882),[69942,69952),[70096,70106),[70113,70133),[70384,70394),[70736,70746),[70864,70874),[71248,71258),[71360,71370),[71376,71396),[71472,71484),[71904,71923),[72016,72026),[72688,72698),[72784,72813),[73040,73050),[73120,73130),[73552,73562),[73664,73685),[74752,74863),[90416,90426),[92768,92778),[92864,92874),[93008,93018),[93019,93026),[93552,93562),[93824,93847),[118000,118010),[119488,119508),[119520,119540),[119648,119673),[120782,120832),[123200,123210),[123632,123642),[124144,124154),[124401,124411),[125127,125136),[125264,125274),[126065,126124),[126125,126128),[126129,126133),[126209,126254),[126255,126270),[127232,127245),[130032,130042)}'::int4multirange;
begin
    if clean_candidate = ''
       or char_length(clean_candidate) > 80
       or octet_length(clean_candidate) > 320 then
        return false;
    end if;

    for codepoint in
        select ascii(substring(nfc_candidate from scalar_index for 1))
        from generate_series(1, char_length(nfc_candidate)) as indices(scalar_index)
    loop
        if codepoint between 0 and 31
           or codepoint between 127 and 159
           or codepoint in (1564, 8206, 8207, 8232, 8233, 65279)
           or codepoint between 8234 and 8238
           or codepoint between 8294 and 8297 then
            return false;
        end if;
    end loop;

    return exists (
        select 1
        from generate_series(1, char_length(clean_candidate)) as indices(scalar_index)
        cross join lateral (
            select substring(clean_candidate from scalar_index for 1) as character
        ) as scalar
        where scalar.character ~ '^[[:alnum:]]$'
           or ascii(scalar.character) <@ number_ranges
           or ascii(scalar.character) <@ symbol_ranges
    );
end;
$$;

create table public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    identity_provider text not null,
    display_name text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint profiles_identity_provider_v1 check (identity_provider in ('google', 'apple')),
    constraint profiles_display_name_length check (
        display_name is null or private.is_valid_display_name_v1(display_name)
    ),
    constraint profiles_display_name_nfc check (
        display_name is null or display_name = private.normalize_display_name_v1(display_name)
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
    constraint workspaces_field_clocks_object check (
        jsonb_typeof(field_clocks) = 'object' and field_clocks <> '{}'::jsonb
    ),
    constraint workspaces_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint workspaces_updated_after_created check (updated_at >= created_at)
);

create unique index workspaces_one_per_owner_v1 on public.workspaces(owner_account_id);

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
    constraint moves_field_clocks_object check (
        jsonb_typeof(field_clocks) = 'object' and field_clocks <> '{}'::jsonb
    ),
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
    constraint appearance_preferences_bounded check (octet_length(preferences::text) <= 262144),
    constraint appearance_revision_positive check (revision > 0),
    constraint appearance_field_clocks_object check (
        jsonb_typeof(field_clocks) = 'object' and field_clocks <> '{}'::jsonb
    ),
    constraint appearance_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint appearance_updated_after_created check (updated_at >= created_at),
    constraint appearance_workspace_entity_unique unique (workspace_id, id)
);

create table public.primary_goals (
    id uuid primary key,
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    title text not null,
    metric text not null default '',
    current_value numeric(30, 8),
    target_value numeric(30, 8),
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
    constraint primary_goals_current_nonnegative check (current_value is null or current_value >= 0),
    constraint primary_goals_target_nonnegative check (target_value is null or target_value >= 0),
    constraint primary_goals_revision_positive check (revision > 0),
    constraint primary_goals_field_clocks_object check (
        jsonb_typeof(field_clocks) = 'object' and field_clocks <> '{}'::jsonb
    ),
    constraint primary_goals_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint primary_goals_updated_after_created check (updated_at >= created_at),
    constraint primary_goals_workspace_entity_unique unique (workspace_id, id)
);

create unique index primary_goals_one_live_per_workspace_v1
    on public.primary_goals(workspace_id)
    where deleted_at is null;

create table public.milestones (
    id uuid primary key,
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    title text not null,
    due_at timestamptz not null,
    deleted_at timestamptz,
    revision bigint not null,
    field_clocks jsonb not null,
    field_writers jsonb not null,
    writer_device_id uuid not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    constraint milestones_title_length check (char_length(btrim(title)) between 1 and 500),
    constraint milestones_revision_positive check (revision > 0),
    constraint milestones_field_clocks_object check (
        jsonb_typeof(field_clocks) = 'object' and field_clocks <> '{}'::jsonb
    ),
    constraint milestones_field_writers_object check (jsonb_typeof(field_writers) = 'object'),
    constraint milestones_updated_after_created check (updated_at >= created_at),
    constraint milestones_workspace_entity_unique unique (workspace_id, id)
);

create index milestones_workspace_due_idx
    on public.milestones(workspace_id, due_at, id)
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
    constraint assets_storage_path_v1 check (
        storage_path = 'workspaces/' || workspace_id::text || '/vision-images/' || id::text || '.jpg'
    ),
    constraint assets_content_type_v1 check (content_type = 'image/jpeg'),
    constraint assets_byte_size_v1 check (byte_size between 1 and 5242880),
    constraint assets_sha256 check (sha256 ~ '^[a-f0-9]{64}$'),
    constraint assets_revision_positive check (revision > 0),
    constraint assets_field_clocks_object check (
        jsonb_typeof(field_clocks) = 'object' and field_clocks <> '{}'::jsonb
    ),
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
        entity_type in ('workspace', 'move', 'appearance', 'primaryGoal', 'milestone', 'asset')
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

create table private.sync_operation_receipts (
    workspace_id uuid not null references public.workspaces(id) on delete cascade,
    operation_id uuid not null,
    operation_envelope jsonb not null,
    result jsonb not null,
    created_at timestamptz not null default now(),
    primary key (workspace_id, operation_id),
    constraint sync_operation_receipts_envelope_object check (
        jsonb_typeof(operation_envelope) = 'object'
    ),
    constraint sync_operation_receipts_result_object check (jsonb_typeof(result) = 'object')
);

create table private.workspace_erasure_receipts (
    workspace_id uuid primary key,
    owner_account_id uuid,
    erased_at timestamptz not null,
    asset_object_count integer not null default 0,
    asset_cleanup_state text not null default 'notRequired',
    constraint workspace_erasure_asset_count_nonnegative check (asset_object_count >= 0),
    constraint workspace_erasure_asset_state_v1 check (
        asset_cleanup_state in ('notRequired', 'verified')
    )
);

comment on table private.workspace_erasure_receipts is
    'Retryable account-scoped receipt; after Auth deletion its account link is nulled while the opaque workspace-ID tombstone permanently prevents resurrection.';

create table private.product_capabilities (
    singleton boolean primary key default true check (singleton),
    asset_storage_enabled boolean not null default false,
    asset_export_verified boolean not null default false,
    asset_erasure_verified boolean not null default false,
    constraint product_capabilities_asset_gate check (
        not asset_storage_enabled or (asset_export_verified and asset_erasure_verified)
    )
);

insert into private.product_capabilities (
    singleton,
    asset_storage_enabled,
    asset_export_verified,
    asset_erasure_verified
) values (true, false, false, false);

create table private.workspace_asset_transfers (
    workspace_id uuid primary key references public.workspaces(id) on delete cascade,
    owner_account_id uuid not null references public.profiles(id) on delete cascade,
    manifest jsonb not null,
    export_verified_at timestamptz,
    deletion_verified_at timestamptz,
    updated_at timestamptz not null default now(),
    constraint workspace_asset_transfers_manifest_array check (jsonb_typeof(manifest) = 'array'),
    constraint workspace_asset_transfers_verified_order check (
        deletion_verified_at is null
        or export_verified_at is null
        or deletion_verified_at >= export_verified_at
    )
);

comment on table private.workspace_asset_transfers is
    'Service-written proof that the exact current private-object manifest was exported or deleted. Authenticated clients receive status but cannot create proof.';

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
        or entity_type in ('workspace', 'move', 'appearance', 'primaryGoal', 'milestone', 'asset')
    ),
    constraint activity_events_entity_pair check (
        (entity_type is null and entity_id is null)
        or (entity_type is not null and entity_id is not null)
    ),
    constraint activity_events_metadata_object check (jsonb_typeof(metadata) = 'object'),
    constraint activity_events_metadata_empty_v1 check (metadata = '{}'::jsonb),
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

create or replace function private.guard_auth_user_product_delete_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if exists (
        select 1
        from public.workspaces as workspace
        where workspace.owner_account_id = old.id
    ) then
        raise exception using
            errcode = 'PT409',
            message = 'erase the product workspace before deleting the Auth identity';
    end if;

    update private.workspace_erasure_receipts as receipt
    set owner_account_id = null
    where receipt.owner_account_id = old.id;
    return old;
end;
$$;

create trigger founder_office_guard_auth_user_delete_v1
before delete on auth.users
for each row execute function private.guard_auth_user_product_delete_v1();

revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;
revoke all on table
    private.sync_operation_receipts,
    private.workspace_erasure_receipts,
    private.product_capabilities,
    private.workspace_asset_transfers
from public, anon, authenticated;
revoke all on function private.is_workspace_owner(uuid) from public, anon, authenticated;
revoke all on function private.guard_auth_user_product_delete_v1() from public, anon, authenticated;
revoke all on function private.normalize_display_name_v1(text) from public, anon, authenticated;
revoke all on function private.is_valid_display_name_v1(text) from public, anon, authenticated;
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
alter table public.milestones enable row level security;
alter table public.milestones force row level security;
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

create policy milestones_owner_select_v1 on public.milestones
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
    public.milestones,
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
    public.milestones,
    public.assets,
    public.activity_events
to authenticated;

commit;
