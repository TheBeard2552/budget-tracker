-- Require a 6-digit numeric PIN for all budget RPCs.
create or replace function public._normalize_pin(p_code text)
returns text
language plpgsql
immutable
as $$
declare
  v_pin text := trim(coalesce(p_code, ''));
begin
  if v_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN must be exactly 6 digits';
  end if;
  return v_pin;
end;
$$;

create or replace function public._budget_id_for_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_pin text := public._normalize_pin(p_code);
begin
  select id into v_id
  from public.budgets
  where code_hash = crypt(v_pin, code_hash)
  limit 1;

  return v_id;
end;
$$;

create or replace function public.create_budget(p_code text, p_weekly numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_pin text := public._normalize_pin(p_code);
begin
  if public._budget_id_for_code(v_pin) is not null then
    raise exception 'A budget already exists for this PIN';
  end if;

  insert into public.budgets (code_hash, weekly_budget)
  values (crypt(v_pin, gen_salt('bf')), p_weekly)
  returning id into v_id;

  return jsonb_build_object(
    'budget_id', v_id,
    'weekly_budget', p_weekly,
    'transactions', '[]'::jsonb
  );
end;
$$;

create or replace function public.unlock_budget(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_weekly numeric;
  v_txs jsonb;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  select weekly_budget into v_weekly from public.budgets where id = v_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', t.id,
      'amount', t.amount,
      'note', t.note,
      'ts', t.ts,
      'source', t.source,
      'card', t.card,
      'categoryOverride', t.category_override
    ) order by t.ts desc
  ), '[]'::jsonb)
  into v_txs
  from public.transactions t
  where t.budget_id = v_id;

  return jsonb_build_object(
    'budget_id', v_id,
    'weekly_budget', v_weekly,
    'transactions', v_txs
  );
end;
$$;

create or replace function public.save_budget_settings(p_code text, p_weekly numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  update public.budgets
  set weekly_budget = p_weekly,
      updated_at = now()
  where id = v_id;

  return jsonb_build_object('ok', true, 'weekly_budget', p_weekly);
end;
$$;

create or replace function public.replace_transactions(p_code text, p_transactions jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_item jsonb;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  if p_transactions is null or jsonb_typeof(p_transactions) <> 'array' then
    raise exception 'transactions must be a JSON array';
  end if;

  delete from public.transactions where budget_id = v_id;

  for v_item in select * from jsonb_array_elements(p_transactions)
  loop
    insert into public.transactions (
      id, budget_id, amount, note, ts, source, card, category_override
    ) values (
      coalesce(v_item->>'id', gen_random_uuid()::text),
      v_id,
      (v_item->>'amount')::numeric,
      coalesce(v_item->>'note', ''),
      (v_item->>'ts')::bigint,
      coalesce(v_item->>'source', 'manual'),
      coalesce(v_item->>'card', ''),
      nullif(v_item->>'categoryOverride', '')
    );
  end loop;

  update public.budgets set updated_at = now() where id = v_id;

  return jsonb_build_object('ok', true, 'count', jsonb_array_length(p_transactions));
end;
$$;

revoke all on function public._normalize_pin(text) from public, anon, authenticated;
revoke all on function public._budget_id_for_code(text) from public, anon, authenticated;
grant execute on function public.create_budget(text, numeric) to anon, authenticated;
grant execute on function public.unlock_budget(text) to anon, authenticated;
grant execute on function public.save_budget_settings(text, numeric) to anon, authenticated;
grant execute on function public.replace_transactions(text, jsonb) to anon, authenticated;
