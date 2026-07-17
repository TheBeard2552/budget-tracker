-- Company name standardization: map messy statement strings → clean company names.
-- Used for spend-by-company grouping. Access via RPCs only (no direct table grants).

create table public.company_aliases (
  id uuid primary key default gen_random_uuid(),
  budget_id uuid not null references public.budgets(id) on delete cascade,
  raw_key text not null,
  company_name text not null,
  created_at timestamptz not null default now(),
  unique (budget_id, raw_key)
);

create index company_aliases_budget_id_idx on public.company_aliases (budget_id);
create index company_aliases_company_name_idx on public.company_aliases (budget_id, company_name);

alter table public.company_aliases enable row level security;
revoke all on table public.company_aliases from anon, authenticated, public;

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
    'company_aliases', '[]'::jsonb,
    'transactions', '[]'::jsonb
  );
end;
$$;

create or replace function public.save_company_aliases(p_code text, p_aliases jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_aliases jsonb;
begin
  v_id := public._budget_id_for_code(p_code);
  if v_id is null then
    raise exception 'Invalid PIN';
  end if;

  if p_aliases is null or jsonb_typeof(p_aliases) <> 'array' then
    raise exception 'aliases must be a JSON array';
  end if;

  delete from public.company_aliases where budget_id = v_id;

  insert into public.company_aliases (budget_id, raw_key, company_name)
  select
    v_id,
    lower(trim(coalesce(elem->>'rawKey', elem->>'raw_key', ''))),
    trim(coalesce(elem->>'companyName', elem->>'company_name', ''))
  from jsonb_array_elements(p_aliases) as elem
  where length(trim(coalesce(elem->>'rawKey', elem->>'raw_key', ''))) >= 2
    and length(trim(coalesce(elem->>'companyName', elem->>'company_name', ''))) >= 1
  on conflict (budget_id, raw_key) do update
    set company_name = excluded.company_name;

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

  update public.budgets set updated_at = now() where id = v_id;

  return jsonb_build_object('ok', true, 'company_aliases', v_aliases);
end;
$$;

grant execute on function public.unlock_budget(text) to anon, authenticated;
grant execute on function public.create_budget(text, numeric) to anon, authenticated;
grant execute on function public.save_company_aliases(text, jsonb) to anon, authenticated;

-- High-confidence seed for the main budget (messy Amex strings → clean companies).
-- Only clear brand / multi-variant merges; ambiguous truncations left alone.
insert into public.company_aliases (budget_id, raw_key, company_name)
select b.id, v.raw_key, v.company_name
from public.budgets b
cross join (values
  -- Retail / grocery
  ('target store', 'Target'),
  ('target.com', 'Target'),
  ('target t-', 'Target'),
  ('safeway', 'Safeway'),
  ('whole foods', 'Whole Foods'),
  ('bi-rite', 'Bi-Rite Market'),
  ('nugget market', 'Nugget Market'),
  ('luke''s local', 'Luke''s Local'),
  ('sprout san fr', 'Sprouts'),
  ('lombard marke', 'Lombard Market'),
  ('sainsbury', 'Sainsbury''s'),
  ('walgreens', 'Walgreens'),
  ('nordstrom', 'Nordstrom'),
  ('zara usa', 'Zara'),
  ('wayfair', 'Wayfair'),
  ('papersource', 'Paper Source'),
  ('sephora', 'Sephora'),
  ('sports basement', 'Sports Basement'),
  ('vuori clothing', 'Vuori'),
  ('the golf mart', 'The Golf Mart'),
  ('sloat garden', 'Sloat Garden Center'),
  ('extra space', 'Extra Space Storage'),
  ('usps kiosk', 'USPS'),
  ('waterstones', 'Waterstones'),
  ('w h smith', 'W H Smith'),

  -- Food / coffee (clear brands + multi-variant)
  ('blue fog mark', 'Blue Fog Market'),
  ('blue fog market', 'Blue Fog Market'),
  ('grubhub*bluefog', 'Blue Fog Market'),
  ('the epicurean', 'The Epicurean Trader'),
  ('epicurean trader', 'The Epicurean Trader'),
  ('philz coffee', 'Philz Coffee'),
  ('philz mobile', 'Philz Coffee'),
  ('spo*rose''s', 'Rose''s Cafe'),
  ('wrecking ball', 'Wrecking Ball Coffee'),
  ('peets', 'Peet''s Coffee'),
  ('q specialty', 'Q Specialty Coffee'),
  ('lil sweet tre', 'Lil Sweet Treat'),
  ('livesweet', 'LiveSweet'),
  ('cafe francisc', 'Cafe Francisco'),
  ('irving subs', 'Irving Subs'),
  ('las mestizas', 'Las Mestizas'),
  ('la corneta', 'La Corneta Taqueria'),
  ('potbelly', 'Potbelly'),
  ('tst* bottles', 'Bottles'),
  ('tst* fieldwor', 'Fieldwork Brewing'),
  ('tst* lucca', 'Lucca Deli'),
  ('tst* earthbar', 'Earthbar'),
  ('tst* wildseed', 'Wildseed'),
  ('dad & sons', 'Dad & Sons Market'),
  ('mums bakehous', 'Mum''s Bakehouse'),
  ('snack* yifang', 'YiFang'),

  -- Delivery / transit / auto
  ('bt*dd *doordas', 'DoorDash'),
  ('doordash', 'DoorDash'),
  ('uber one', 'Uber'),
  ('uber', 'Uber'),
  ('waymo', 'Waymo'),
  ('fastrak', 'FasTrak'),
  ('caltrain', 'Caltrain'),
  ('tcb  mta mete', 'SF MTA Meter'),
  ('mta meter', 'SF MTA Meter'),
  ('chevron', 'Chevron'),
  ('shell service', 'Shell'),
  ('csaa insurance', 'CSAA Insurance'),
  ('jetblue', 'JetBlue'),
  ('ba inflight', 'British Airways Inflight'),

  -- Utilities / gov / insurance / health
  ('pacific gas and elec', 'PG&E'),
  ('ez pay fee pge', 'PG&E'),
  ('sf water power', 'SF Water'),
  ('ca dmv fee', 'California DMV'),
  ('state of calif dmv', 'California DMV'),
  ('dr. treat veterinary', 'Dr. Treat Veterinary'),
  ('sfbamboonails', 'SF Bamboo Nails'),
  ('hiya health', 'Hiya Health'),
  ('froya organics', 'Froya Organics'),
  ('forever healthy', 'Forever Healthy'),
  ('innovative health', 'Innovative Health'),

  -- Streaming / software
  ('disney plus', 'Disney+'),
  ('youtube tv', 'YouTube TV'),
  ('hulu', 'Hulu'),
  ('paramount+', 'Paramount+'),
  ('cursor, ai powered', 'Cursor'),
  ('elevenlabs', 'ElevenLabs'),
  ('vectorizerai', 'Vectorizer AI'),

  -- Kids / pets / home brands
  ('kidsland', 'Kidsland'),
  ('minicoton', 'Minicoton'),
  ('nini and loli', 'Nini and Loli'),
  ('dont eat m', 'Don''t Eat Me'),
  ('wondergart', 'Wondergarden'),

  -- Golf / Scotland (high confidence brands / venues)
  ('presidio golf', 'Presidio Golf Course'),
  ('presidio trust parki', 'Presidio Trust Parking'),
  ('kingsbarns', 'Kingsbarns Golf'),
  ('st andrews links', 'St Andrews Links'),
  ('ls st andrews links', 'St Andrews Links'),
  ('gullane golf', 'Gullane Golf'),
  ('dojo*gullane', 'Gullane Golf'),
  ('dojo*dumbarnie', 'Dumbarnie Golf'),
  ('dumbarnie golf', 'Dumbarnie Golf'),
  ('dojo*the keys', 'The Keys Bar'),
  ('the keys bar', 'The Keys Bar'),
  ('dojo*the bonn', 'The Bonnie Badger'),
  ('the bonnie badg', 'The Bonnie Badger'),
  ('dojo*black bu', 'Black Bull'),
  ('the kithmore', 'The Kithmore Hotel'),
  ('kithmore hotel', 'The Kithmore Hotel'),
  ('nb pro shop', 'North Berwick Pro Shop'),
  ('forgans', 'Forgans'),
  ('house of cash', 'House of Cashmere'),
  ('ukvi', 'UKVI'),
  ('california ka', 'California Academy of Sciences'),
  ('py *california wine', 'California Wine Merchant'),
  ('levy@ sfba', 'Levi''s Stadium'),
  ('istore @sfo', 'Apple Store SFO'),
  ('fedex office', 'FedEx Office'),
  ('hudson st2355', 'Hudson News'),
  ('bos airp mija', 'Mija Cantina'),
  ('the pop natio', 'The Pop Nation'),
  ('madeby', 'Madeby')
) as v(raw_key, company_name)
where b.id = '6ee028c9-2ded-47c1-b991-584a5ea3753d'
on conflict (budget_id, raw_key) do update
  set company_name = excluded.company_name;
