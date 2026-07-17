-- Weekly dinner menu: map of weekStart (Mon YYYY-MM-DD) → array of 7 dinner strings (Mon..Sun).

alter table public.budgets
  add column if not exists weekly_menu jsonb not null default '{}'::jsonb;

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
  v_aliases jsonb;
  v_events jsonb;
  v_txs jsonb;
  v_gcal text;
  v_menu jsonb;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  select weekly_budget, categories, merchant_rules, gcal_calendar_id, weekly_menu
  into v_weekly, v_cats, v_rules, v_gcal, v_menu
  from public.budgets
  where id = v_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', a.id,
      'rawKey', a.raw_key,
      'companyName', a.company_name
    ) order by a.company_name, a.raw_key
  ), '[]'::jsonb)
  into v_aliases
  from public.company_aliases a
  where a.budget_id = v_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id,
      'title', e.title,
      'notes', e.notes,
      'startTs', e.start_ts,
      'endTs', e.end_ts,
      'allDay', e.all_day,
      'person', e.person,
      'gcalEventId', e.gcal_event_id
    ) order by e.start_ts, e.title
  ), '[]'::jsonb)
  into v_events
  from public.calendar_events e
  where e.budget_id = v_id;

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
    'company_aliases', coalesce(v_aliases, '[]'::jsonb),
    'calendar_events', coalesce(v_events, '[]'::jsonb),
    'gcal_calendar_id', v_gcal,
    'weekly_menu', coalesce(v_menu, '{}'::jsonb),
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

  insert into public.budgets (code_hash, weekly_budget, categories, merchant_rules, weekly_menu)
  values (crypt(v_pin, gen_salt('bf')), p_weekly, '[]'::jsonb, '[]'::jsonb, '{}'::jsonb)
  returning id into v_id;

  return jsonb_build_object(
    'budget_id', v_id,
    'weekly_budget', p_weekly,
    'categories', '[]'::jsonb,
    'merchant_rules', '[]'::jsonb,
    'company_aliases', '[]'::jsonb,
    'calendar_events', '[]'::jsonb,
    'gcal_calendar_id', null,
    'weekly_menu', '{}'::jsonb,
    'transactions', '[]'::jsonb
  );
end;
$$;

create or replace function public.save_weekly_menu(p_code text, p_weekly_menu jsonb)
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

  if p_weekly_menu is null or jsonb_typeof(p_weekly_menu) <> 'object' then
    raise exception 'weekly_menu must be a JSON object';
  end if;

  update public.budgets
  set weekly_menu = p_weekly_menu,
      updated_at = now()
  where id = v_id;

  return jsonb_build_object('ok', true, 'weekly_menu', p_weekly_menu);
end;
$$;

grant execute on function public.unlock_budget(text) to anon, authenticated;
grant execute on function public.create_budget(text, numeric) to anon, authenticated;
grant execute on function public.save_weekly_menu(text, jsonb) to anon, authenticated;
