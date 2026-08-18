-- ============================================================================
-- إضافة منتج Winner Radar إلى قاعدة بيانات BOTSHOP-DZ الحالية
-- آمن للتنفيذ على قاعدة بيانات تعمل بالفعل (لا يمسّ أي جدول موجود)
-- ============================================================================

-- 1) عمود محاولات Winner Radar التجريبية في جدول stores
alter table public.stores
  add column if not exists winner_radar_trial_remaining integer not null default 3;

-- 2) قاعدة الموردين (Blackbook) — يديرها المشرف فقط
create table if not exists public.suppliers_blackbook (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  phone text not null,
  wilaya text not null,
  niche text not null,
  notes text,
  is_active boolean not null default true,
  added_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_blackbook_niche on public.suppliers_blackbook(niche);
create index if not exists idx_blackbook_wilaya on public.suppliers_blackbook(wilaya);

alter table public.suppliers_blackbook enable row level security;

drop policy if exists "blackbook_select_merchants" on public.suppliers_blackbook;
create policy "blackbook_select_merchants"
  on public.suppliers_blackbook for select
  using (
    (is_active = true and exists (
      select 1 from public.profiles p where p.id = auth.uid() and p.role in ('supplier','retailer','contracted')
    ))
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

drop policy if exists "blackbook_modify_admin_only" on public.suppliers_blackbook;
create policy "blackbook_modify_admin_only"
  on public.suppliers_blackbook for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

drop trigger if exists trg_blackbook_updated_at on public.suppliers_blackbook;
create trigger trg_blackbook_updated_at before update on public.suppliers_blackbook
  for each row execute function public.fn_set_updated_at();

-- 3) فلتر الجدوى اللوجستية (مجاني وغير محدود لكل التجار)
create table if not exists public.winner_radar_logistics_checks (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  product_idea text,
  has_liquids boolean not null default false,
  is_oversized boolean not null default false,
  needs_sizing boolean not null default false,
  risk_level text not null default 'low',
  created_at timestamptz not null default now()
);

create index if not exists idx_logistics_checks_store on public.winner_radar_logistics_checks(store_id);

alter table public.winner_radar_logistics_checks enable row level security;

drop policy if exists "logistics_checks_select_own" on public.winner_radar_logistics_checks;
create policy "logistics_checks_select_own"
  on public.winner_radar_logistics_checks for select
  using (
    exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

drop policy if exists "logistics_checks_insert_own" on public.winner_radar_logistics_checks;
create policy "logistics_checks_insert_own"
  on public.winner_radar_logistics_checks for insert
  with check (exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

create or replace function public.fn_calculate_logistics_risk()
returns trigger as $$
begin
  if new.has_liquids then
    new.risk_level := 'high';
  elsif new.is_oversized and new.needs_sizing then
    new.risk_level := 'high';
  elsif new.is_oversized or new.needs_sizing then
    new.risk_level := 'medium';
  else
    new.risk_level := 'low';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_calculate_logistics_risk on public.winner_radar_logistics_checks;
create trigger trg_calculate_logistics_risk
  before insert on public.winner_radar_logistics_checks
  for each row execute function public.fn_calculate_logistics_risk();

-- 4) طلبات الذكاء الاصطناعي (محرك التحليل + مولّد المحتوى) — محكومة بسقف المحاولات
create table if not exists public.winner_radar_requests (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  request_type text not null check (request_type in ('ad_analyzer', 'content_generator')),
  input_text text not null,
  output_text text,
  market_saturation_level text check (market_saturation_level in ('low','medium','high')),
  created_at timestamptz not null default now()
);

create index if not exists idx_wr_requests_store on public.winner_radar_requests(store_id);

alter table public.winner_radar_requests enable row level security;

drop policy if exists "wr_requests_select_own" on public.winner_radar_requests;
create policy "wr_requests_select_own"
  on public.winner_radar_requests for select
  using (
    exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

drop policy if exists "wr_requests_insert_own" on public.winner_radar_requests;
create policy "wr_requests_insert_own"
  on public.winner_radar_requests for insert
  with check (exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

create or replace function public.fn_enforce_winner_radar_trial()
returns trigger as $$
declare
  v_plan plan_type;
  v_remaining integer;
begin
  select plan, winner_radar_trial_remaining into v_plan, v_remaining
    from public.stores where id = new.store_id;

  if v_plan not in ('pro', 'enterprise') then
    if v_remaining <= 0 then
      raise exception 'انتهت محاولاتك التجريبية المجانية لـ Winner Radar. يرجى ترقية خطتك إلى الاحترافية أو المؤسساتية للاستمرار.'
        using errcode = 'P0002';
    end if;
    update public.stores set winner_radar_trial_remaining = winner_radar_trial_remaining - 1 where id = new.store_id;
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_enforce_winner_radar_trial on public.winner_radar_requests;
create trigger trg_enforce_winner_radar_trial
  before insert on public.winner_radar_requests
  for each row execute function public.fn_enforce_winner_radar_trial();

-- 5) جلسات محرك قرار الاختبار — تربط كل الوحدات لمنتج واحد وتحسب صافي الربح والقرار تلقائياً
create table if not exists public.winner_radar_sessions (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  product_idea text not null,
  purchase_price numeric(10,2),
  suggested_sale_price numeric(10,2),
  shipping_cost numeric(10,2),
  estimated_return_rate_pct numeric(5,2),
  estimated_ad_budget numeric(10,2),
  net_profit numeric(10,2),
  net_margin_pct numeric(5,2),
  verdict text check (verdict in ('go','caution','stop')),
  logistics_check_id uuid references public.winner_radar_logistics_checks(id) on delete set null,
  ad_analysis_id uuid references public.winner_radar_requests(id) on delete set null,
  content_generation_id uuid references public.winner_radar_requests(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_wr_sessions_store on public.winner_radar_sessions(store_id);

alter table public.winner_radar_sessions enable row level security;

drop policy if exists "wr_sessions_select_own" on public.winner_radar_sessions;
create policy "wr_sessions_select_own"
  on public.winner_radar_sessions for select
  using (
    exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

drop policy if exists "wr_sessions_modify_own" on public.winner_radar_sessions;
create policy "wr_sessions_modify_own"
  on public.winner_radar_sessions for all
  using (exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

drop trigger if exists trg_wr_sessions_updated_at on public.winner_radar_sessions;
create trigger trg_wr_sessions_updated_at before update on public.winner_radar_sessions
  for each row execute function public.fn_set_updated_at();

create or replace function public.fn_calculate_winner_radar_verdict()
returns trigger as $$
declare
  v_logistics_risk text;
  v_market_saturation text;
begin
  new.net_profit := coalesce(new.suggested_sale_price,0) - coalesce(new.purchase_price,0)
                     - coalesce(new.shipping_cost,0)
                     - (coalesce(new.suggested_sale_price,0) * coalesce(new.estimated_return_rate_pct,0) / 100)
                     - coalesce(new.estimated_ad_budget,0);

  new.net_margin_pct := case when coalesce(new.suggested_sale_price,0) > 0
    then round((new.net_profit / new.suggested_sale_price) * 100, 2)
    else null end;

  if new.logistics_check_id is not null then
    select risk_level into v_logistics_risk
      from public.winner_radar_logistics_checks where id = new.logistics_check_id;
  end if;
  if new.ad_analysis_id is not null then
    select market_saturation_level into v_market_saturation
      from public.winner_radar_requests where id = new.ad_analysis_id;
  end if;

  if v_logistics_risk = 'high' or (new.net_margin_pct is not null and new.net_margin_pct < 10) then
    new.verdict := 'stop';
  elsif v_logistics_risk = 'medium' or v_market_saturation = 'high'
        or (new.net_margin_pct is not null and new.net_margin_pct < 20) then
    new.verdict := 'caution';
  elsif new.logistics_check_id is not null and new.net_margin_pct is not null then
    new.verdict := 'go';
  else
    new.verdict := null;
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_calculate_winner_radar_verdict on public.winner_radar_sessions;
create trigger trg_calculate_winner_radar_verdict
  before insert or update on public.winner_radar_sessions
  for each row execute function public.fn_calculate_winner_radar_verdict();
