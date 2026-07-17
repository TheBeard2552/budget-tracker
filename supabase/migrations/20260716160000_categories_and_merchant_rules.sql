-- Custom categories + merchant memory (where you bought → category) for future auto-tagging.

alter table public.budgets
  add column if not exists categories jsonb not null default '[]'::jsonb,
  add column if not exists merchant_rules jsonb not null default '[]'::jsonb;

create or replace function public.unlock_budget(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_weekly numeric;
  v_cats jsonb;
  v_rules jsonb;
  v_txs jsonb;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  select weekly_budget, categories, merchant_rules
  into v_weekly, v_cats, v_rules
  from public.budgets
  where id = v_id;

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
    'categories', coalesce(v_cats, '[]'::jsonb),
    'merchant_rules', coalesce(v_rules, '[]'::jsonb),
    'transactions', v_txs
  );
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

  insert into public.budgets (code_hash, weekly_budget, categories, merchant_rules)
  values (crypt(v_pin, gen_salt('bf')), p_weekly, '[]'::jsonb, '[]'::jsonb)
  returning id into v_id;

  return jsonb_build_object(
    'budget_id', v_id,
    'weekly_budget', p_weekly,
    'categories', '[]'::jsonb,
    'merchant_rules', '[]'::jsonb,
    'transactions', '[]'::jsonb
  );
end;
$$;

create or replace function public.save_taxonomy(p_code text, p_categories jsonb, p_merchant_rules jsonb)
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

  if p_categories is null or jsonb_typeof(p_categories) <> 'array' then
    raise exception 'categories must be a JSON array';
  end if;
  if p_merchant_rules is null or jsonb_typeof(p_merchant_rules) <> 'array' then
    raise exception 'merchant_rules must be a JSON array';
  end if;

  update public.budgets
  set categories = p_categories,
      merchant_rules = p_merchant_rules,
      updated_at = now()
  where id = v_id;

  return jsonb_build_object(
    'ok', true,
    'categories', p_categories,
    'merchant_rules', p_merchant_rules
  );
end;
$$;

grant execute on function public.unlock_budget(text) to anon, authenticated;
grant execute on function public.create_budget(text, numeric) to anon, authenticated;
grant execute on function public.save_taxonomy(text, jsonb, jsonb) to anon, authenticated;
