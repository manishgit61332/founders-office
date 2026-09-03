-- The push RPC intentionally uses its operation envelope's field clocks on
-- the right-hand side of update statements. PostgreSQL 17's stricter PL/pgSQL
-- analysis otherwise treats `field_clocks` as ambiguous because the target
-- tables also expose a column with that name.
--
-- Keep the existing API and body stable while making the intended variable
-- precedence explicit for compilation and runtime execution. A compiler
-- directive is used because hosted Supabase roles cannot change the
-- superuser-only `plpgsql.variable_conflict` setting.
do $migration$
declare
    function_definition text;
    updated_definition text;
begin
    select pg_get_functiondef(
        'public.push_operations(uuid, uuid, jsonb)'::regprocedure
    )
    into function_definition;

    updated_definition := replace(
        function_definition,
        E'AS $function$\n',
        E'AS $function$\n#variable_conflict use_variable\n'
    );

    if updated_definition = function_definition then
        raise exception 'could not install push_operations conflict directive';
    end if;

    execute updated_definition;
end;
$migration$;
