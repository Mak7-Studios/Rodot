begin;

create schema if not exists rodot_private;

create table if not exists rodot_private.datastore_entries (
    namespace text not null,
    store_name text not null,
    store_scope text not null,
    entry_key text not null,
    data jsonb not null,
    revision text not null,
    primary key (namespace, store_name, store_scope, entry_key)
);

alter table rodot_private.datastore_entries enable row level security;
revoke all on schema rodot_private from public, anon, authenticated;
revoke all on table rodot_private.datastore_entries from public, anon, authenticated;
grant usage on schema rodot_private to service_role;
grant select, insert, update, delete on table rodot_private.datastore_entries to service_role;

create or replace function public.rodot_datastore(request jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $function$
declare
    op text := request->>'op';
    p_namespace text := request->>'project';
    p_store text := request->>'store';
    p_scope text := request->>'scope';
    p_key text := request->>'key';
    previous rodot_private.datastore_entries%rowtype;
    had_entry boolean;
    prior_result jsonb;
    next_data jsonb := request->'value';
    next_revision text;
    delta numeric;
    counter numeric;
begin
    if op is null or op not in ('get', 'set', 'increment', 'remove', 'compare_and_set') then
        return jsonb_build_object('ok', false, 'error', 'Unknown DataStore operation');
    end if;
    if exists (
        select 1 from unnest(array[p_namespace, p_store, p_scope, p_key]) as part(value)
        where value is null or octet_length(value) not between 1 and 128
    ) then
        return jsonb_build_object('ok', false, 'error', 'Invalid DataStore namespace, store, scope or key');
    end if;

    if op <> 'get' then
        perform pg_advisory_xact_lock(hashtextextended(jsonb_build_array(p_namespace, p_store, p_scope, p_key)::text, 0));
    end if;

    select entry.* into previous
    from rodot_private.datastore_entries as entry
    where entry.namespace = p_namespace and entry.store_name = p_store
        and entry.store_scope = p_scope and entry.entry_key = p_key;
    had_entry := found;
    if had_entry then
        prior_result := jsonb_build_object('data', previous.data, 'revision', previous.revision);
    end if;

    if op = 'get' then
        return jsonb_build_object('ok', true, 'result', prior_result);
    elsif op = 'remove' then
        delete from rodot_private.datastore_entries as entry
        where entry.namespace = p_namespace and entry.store_name = p_store
            and entry.store_scope = p_scope and entry.entry_key = p_key;
        return jsonb_build_object('ok', true, 'result', prior_result);
    elsif op = 'compare_and_set' then
        if jsonb_typeof(request->'revision') is distinct from 'string' then
            return jsonb_build_object('ok', false, 'error', 'Expected a DataStore revision');
        end if;
        if coalesce(previous.revision, '') <> request->>'revision' then
            return jsonb_build_object('ok', true, 'result', false);
        end if;
    elsif op = 'increment' then
        if next_data is null or next_data = 'null'::jsonb then
            next_data := '1'::jsonb;
        end if;
        if jsonb_typeof(next_data) <> 'number' or (had_entry and jsonb_typeof(previous.data) <> 'number') then
            return jsonb_build_object('ok', false, 'error', 'IncrementAsync requires integers');
        end if;
        delta := next_data::text::numeric;
        counter := case when had_entry then previous.data::text::numeric else 0 end;
        if trunc(delta) <> delta or trunc(counter) <> counter or abs(delta) > 9007199254740991
            or abs(counter) > 9007199254740991 or abs(counter + delta) > 9007199254740991 then
            return jsonb_build_object('ok', false, 'error', 'IncrementAsync exceeds the exact integer range');
        end if;
        next_data := to_jsonb((counter + delta)::bigint);
    end if;

    if next_data is null or next_data = 'null'::jsonb or octet_length(next_data::text) > 2097152 then
        return jsonb_build_object('ok', false, 'error', 'DataStore value must be non-null and at most 2 MiB');
    end if;
    next_revision := gen_random_uuid()::text;
    insert into rodot_private.datastore_entries (namespace, store_name, store_scope, entry_key, data, revision)
    values (p_namespace, p_store, p_scope, p_key, next_data, next_revision)
    on conflict (namespace, store_name, store_scope, entry_key)
    do update set data = excluded.data, revision = excluded.revision;

    if op = 'increment' then
        return jsonb_build_object('ok', true, 'result', next_data);
    end if;
    return jsonb_build_object('ok', true, 'result', next_revision);
end;
$function$;

revoke all on function public.rodot_datastore(jsonb) from public, anon, authenticated;
grant execute on function public.rodot_datastore(jsonb) to service_role;
notify pgrst, 'reload schema';

commit;
