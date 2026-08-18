-- ============================================================================
-- BOTSHOP-DZ — مخطط قاعدة البيانات (Supabase / PostgreSQL)
-- الإصدار: 1.0
-- ملاحظة: نظام القائمة السوداء معتمد وفق التوصيف الأصلي:
--   أخضر: أقل من 3 مرتجعات | برتقالي: أقل من 5 مرتجعات | أحمر: 5 مرتجعات فأكثر
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. الإضافات (Extensions)
-- ----------------------------------------------------------------------------
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. الأنواع المعرّفة (ENUMs)
-- ----------------------------------------------------------------------------
create type user_role as enum (
  'admin', 'supplier', 'retailer', 'contracted', 'customer', 'founder', 'influencer'
);

create type store_type as enum ('supplier', 'retailer', 'contracted');

create type plan_type as enum ('free', 'basic', 'pro', 'enterprise');

create type founder_tier as enum ('gold', 'silver');

create type payment_method as enum ('ccp', 'baridimob', 'cib_chargily', 'payzone', 'cod');

create type payment_status as enum ('pending', 'paid', 'verified_manual', 'refunded', 'failed');

create type order_status as enum ('processing', 'confirmed', 'shipped', 'delivered', 'returned', 'cancelled');

create type delivery_company as enum ('yalidine', 'z_express', 'k_express', 'dhl_dz', 'other');

create type referral_type as enum ('merchant', 'customer');

create type blacklist_color as enum ('green', 'orange', 'red');

create type contract_status as enum ('pending', 'active', 'revoked', 'expired');

-- ----------------------------------------------------------------------------
-- 2. profiles — يوسّع auth.users
-- ----------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role user_role not null default 'customer',
  full_name text not null,
  phone text unique not null,
  wilaya text not null,
  store_name text,
  referral_code text unique not null default substr(replace(uuid_generate_v4()::text, '-', ''), 1, 8),
  referred_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_profiles_role on public.profiles(role);
create index idx_profiles_referred_by on public.profiles(referred_by);
create index idx_profiles_phone on public.profiles(phone);

alter table public.profiles enable row level security;

create policy "profiles_select_own_or_admin"
  on public.profiles for select
  using (auth.uid() = id or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "profiles_update_own"
  on public.profiles for update
  using (auth.uid() = id);

create policy "profiles_insert_own"
  on public.profiles for insert
  with check (auth.uid() = id);

-- ----------------------------------------------------------------------------
-- 3. stores
-- ----------------------------------------------------------------------------
create table public.stores (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  store_type store_type not null,
  plan plan_type not null default 'free',
  subscription_start timestamptz not null default now(),
  subscription_end timestamptz,
  orders_used integer not null default 0, -- يُزاد تلقائياً عند إنشاء كل طلب جديد (وليس عند نجاحه)
  orders_limit integer not null default 10, -- 10 مدى الحياة للمجانية، يُحدّث عند الترقية
  free_plan_lifetime_used boolean not null default false, -- يمنع تكرار العرض المجاني
  balance numeric(12,2) not null default 0, -- رصيد داخلي (مساعدة المرتجعات + مكافأة إحالة التجار)، غير نقدي، يُستعمل حصراً لترقية/تجديد الاشتراك
  returns_assisted_count integer not null default 0, -- عدد المرتجعات المدعومة ضمن سقف الخطة الحالية (10/13/25/34)
  winner_radar_trial_remaining integer not null default 3, -- محاولات تجريبية مجانية لميزة Winner Radar (خارج الخطط الاحترافية/المؤسساتية)
  blacklist_enabled boolean not null default false, -- pro/enterprise فقط
  instant_assistance boolean not null default false, -- enterprise فقط
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_id) -- متجر واحد لكل تاجر
);

create index idx_stores_owner on public.stores(owner_id);
create index idx_stores_plan on public.stores(plan);
create index idx_stores_type on public.stores(store_type);

alter table public.stores enable row level security;

create policy "stores_select_public_active"
  on public.stores for select
  using (is_active = true or owner_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "stores_modify_own"
  on public.stores for all
  using (owner_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ----------------------------------------------------------------------------
-- 4. subscription_history
-- ----------------------------------------------------------------------------
create table public.subscription_history (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  old_plan plan_type,
  new_plan plan_type not null,
  amount_paid numeric(10,2) not null default 0,
  payment_reference text,
  changed_at timestamptz not null default now()
);

create index idx_sub_history_store on public.subscription_history(store_id);

alter table public.subscription_history enable row level security;

create policy "sub_history_select_own"
  on public.subscription_history for select
  using (exists (select 1 from public.stores s where s.id = store_id and (s.owner_id = auth.uid()))
         or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ----------------------------------------------------------------------------
-- 5. products
-- ----------------------------------------------------------------------------
create table public.products (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  title text not null,
  description text,
  price numeric(10,2) not null check (price >= 0),
  stock integer not null default 0 check (stock >= 0),
  images jsonb not null default '[]', -- حتى 3 روابط صور مضغوطة
  video_url text, -- خاص بالمتجر وليس المنتج (اختياري 15-25 ثانية)
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint max_3_images check (jsonb_array_length(images) <= 3)
);

create index idx_products_store on public.products(store_id);
create index idx_products_active on public.products(is_active);

alter table public.products enable row level security;

create policy "products_select_public"
  on public.products for select
  using (is_active = true or exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

create policy "products_modify_own_store"
  on public.products for all
  using (exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

-- ----------------------------------------------------------------------------
-- 6. supplier_contracts (بين المورّد والتاجر المتعاقد)
-- ----------------------------------------------------------------------------
create table public.supplier_contracts (
  id uuid primary key default uuid_generate_v4(),
  supplier_id uuid not null references public.stores(id) on delete cascade,
  contracted_store_id uuid not null references public.stores(id) on delete cascade,
  agreed_commission numeric(6,2) not null, -- عمولة التاجر المتعاقد، يحددها تاجر الجملة/التجزئة بحرية (نسبة % أو مبلغ ثابت)
  platform_monthly_fee numeric(10,2) not null default 500, -- فائدة المنصة الرمزية الثابتة من هذا العقد
  terms_text text not null, -- نص العقد الشرعي الكامل
  status contract_status not null default 'pending',
  signed_by_supplier_at timestamptz,
  signed_by_contracted_at timestamptz,
  signer_ip_supplier text,
  signer_ip_contracted text,
  created_at timestamptz not null default now(),
  check (supplier_id != contracted_store_id)
);

create index idx_contracts_supplier on public.supplier_contracts(supplier_id);
create index idx_contracts_contracted on public.supplier_contracts(contracted_store_id);

alter table public.supplier_contracts enable row level security;

create policy "contracts_select_parties"
  on public.supplier_contracts for select
  using (
    exists (select 1 from public.stores s where s.id = supplier_id and s.owner_id = auth.uid())
    or exists (select 1 from public.stores s where s.id = contracted_store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

create policy "contracts_modify_parties"
  on public.supplier_contracts for all
  using (
    exists (select 1 from public.stores s where s.id = supplier_id and s.owner_id = auth.uid())
    or exists (select 1 from public.stores s where s.id = contracted_store_id and s.owner_id = auth.uid())
  );

-- ----------------------------------------------------------------------------
-- 7. contracted_products (منتجات المورّد المعروضة عند المتعاقد)
-- ----------------------------------------------------------------------------
create table public.contracted_products (
  id uuid primary key default uuid_generate_v4(),
  contract_id uuid not null references public.supplier_contracts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  custom_price numeric(10,2) not null check (custom_price >= 0),
  created_at timestamptz not null default now(),
  unique(contract_id, product_id)
);

create index idx_contracted_products_contract on public.contracted_products(contract_id);

alter table public.contracted_products enable row level security;

create policy "contracted_products_select_all"
  on public.contracted_products for select
  using (true);

create policy "contracted_products_modify_parties"
  on public.contracted_products for all
  using (
    exists (
      select 1 from public.supplier_contracts c
      join public.stores s on (s.id = c.supplier_id or s.id = c.contracted_store_id)
      where c.id = contract_id and s.owner_id = auth.uid()
    )
  );

-- ----------------------------------------------------------------------------
-- 7.1 contract_platform_fees (فوترة رسوم المنصة الرمزية 500 دج/الشهر لكل عقد نشط)
-- ----------------------------------------------------------------------------
create table public.contract_platform_fees (
  id uuid primary key default uuid_generate_v4(),
  contract_id uuid not null references public.supplier_contracts(id) on delete cascade,
  month date not null, -- أول يوم من الشهر المفوتَر
  amount numeric(10,2) not null default 500,
  status text not null default 'pending', -- pending, paid
  created_at timestamptz not null default now(),
  unique(contract_id, month)
);

create index idx_contract_fees_contract on public.contract_platform_fees(contract_id);

alter table public.contract_platform_fees enable row level security;

create policy "contract_fees_select_parties"
  on public.contract_platform_fees for select
  using (
    exists (
      select 1 from public.supplier_contracts c
      join public.stores s on (s.id = c.supplier_id or s.id = c.contracted_store_id)
      where c.id = contract_id and s.owner_id = auth.uid()
    )
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- ----------------------------------------------------------------------------
-- 8. orders
-- ----------------------------------------------------------------------------
create table public.orders (
  id uuid primary key default uuid_generate_v4(),
  order_number text unique, -- رقم طلب مقروء يُولَّد تلقائياً (مثال: ORD-10432)، يُستعمل للتتبع عبر Typebot وواجهات العرض
  store_id uuid not null references public.stores(id) on delete restrict,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity integer not null default 1 check (quantity > 0),
  total_product_price numeric(10,2) not null check (total_product_price >= 0),
  shipping_cost numeric(10,2) not null default 0,
  shipping_address text, -- عنوان التوصيل التفصيلي (شارع/حي)، بالإضافة إلى ولاية العميل المسجّلة في profiles
  payment_method payment_method not null,
  payment_status payment_status not null default 'pending',
  order_status order_status not null default 'processing',
  tracking_number text,
  delivery_company delivery_company,
  commission_amount numeric(10,2) not null default 0, -- محسوبة حسب خطة المتجر عند نجاح الطلب
  referral_discount_applied numeric(10,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_orders_store on public.orders(store_id);
create index idx_orders_customer on public.orders(customer_id);
create index idx_orders_status on public.orders(order_status);
create index idx_orders_created on public.orders(created_at desc);
create index idx_orders_order_number on public.orders(order_number);

alter table public.orders enable row level security;

create policy "orders_select_store_or_customer"
  on public.orders for select
  using (
    customer_id = auth.uid()
    or exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

create policy "orders_insert_customer"
  on public.orders for insert
  with check (customer_id = auth.uid());

create policy "orders_update_store_owner"
  on public.orders for update
  using (exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

-- ----------------------------------------------------------------------------
-- 9. returns
-- ----------------------------------------------------------------------------
create table public.returns (
  id uuid primary key default uuid_generate_v4(),
  order_id uuid not null references public.orders(id) on delete cascade,
  return_shipping_cost numeric(10,2) not null default 0,
  assistance_percentage numeric(5,2) not null, -- 15/30/40/50 حسب الخطة وقت الإرجاع
  refund_amount numeric(10,2) not null default 0, -- يُحتسب = return_shipping_cost * assistance_percentage
  status text not null default 'documented', -- documented, credited
  documented_at timestamptz not null default now()
);

create index idx_returns_order on public.returns(order_id);

alter table public.returns enable row level security;

create policy "returns_select_store_owner"
  on public.returns for select
  using (
    exists (
      select 1 from public.orders o join public.stores s on s.id = o.store_id
      where o.id = order_id and s.owner_id = auth.uid()
    )
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- ----------------------------------------------------------------------------
-- 10. referrals (إحالة التجار والعملاء)
-- ----------------------------------------------------------------------------
create table public.referrals (
  id uuid primary key default uuid_generate_v4(),
  referrer_id uuid not null references public.profiles(id) on delete cascade,
  referred_id uuid not null references public.profiles(id) on delete cascade,
  type referral_type not null,
  discount_code text unique,
  discount_amount numeric(10,2),
  used boolean not null default false,
  order_id uuid references public.orders(id) on delete set null,
  created_at timestamptz not null default now(),
  check (referrer_id != referred_id)
);

create index idx_referrals_referrer on public.referrals(referrer_id);
create index idx_referrals_referred on public.referrals(referred_id);
create index idx_referrals_code on public.referrals(discount_code);

alter table public.referrals enable row level security;

create policy "referrals_select_own"
  on public.referrals for select
  using (referrer_id = auth.uid() or referred_id = auth.uid()
         or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ----------------------------------------------------------------------------
-- 11. merchant_referral_bonus (رصيد إحالة التجار — 500 دج لكل إحالة ناجحة)
-- ----------------------------------------------------------------------------
create table public.merchant_referral_bonus (
  id uuid primary key default uuid_generate_v4(),
  referrer_store_id uuid not null references public.stores(id) on delete cascade,
  referred_store_id uuid not null references public.stores(id) on delete cascade,
  bonus_amount numeric(10,2) not null default 500,
  status text not null default 'pending', -- pending, credited
  created_at timestamptz not null default now(),
  unique(referred_store_id) -- كل متجر مُحال يُحسب مرة واحدة فقط
);

create index idx_merchant_bonus_referrer on public.merchant_referral_bonus(referrer_store_id);

alter table public.merchant_referral_bonus enable row level security;

create policy "merchant_bonus_select_own"
  on public.merchant_referral_bonus for select
  using (
    exists (select 1 from public.stores s where s.id = referrer_store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- ----------------------------------------------------------------------------
-- 12. founding_merchants (التجار المؤسسون: ذهبي/فضي)
-- ----------------------------------------------------------------------------
create table public.founding_merchants (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade unique,
  tier founder_tier not null, -- gold يستهدف اشتراك الخطة 'pro' (الاحترافية)، silver يستهدف 'basic' (الأساسية)
  qualifying_referrals_count integer not null default 0,
  lifetime_discount_percentage numeric(5,2) not null default 20,
  commission_reduction_percentage numeric(5,2) not null default 50,
  qualified_at timestamptz not null default now()
);

alter table public.founding_merchants enable row level security;

create policy "founders_select_own_or_public"
  on public.founding_merchants for select
  using (true);

-- ----------------------------------------------------------------------------
-- 13. influencers (المؤثرون — عمولة 300 دج/شهر ما دام التاجر مشتركاً)
-- ----------------------------------------------------------------------------
create table public.influencers (
  id uuid primary key default uuid_generate_v4(),
  profile_id uuid not null references public.profiles(id) on delete cascade unique,
  influencer_code text unique not null default substr(replace(uuid_generate_v4()::text, '-', ''), 1, 8),
  created_at timestamptz not null default now()
);

create table public.influencer_commissions (
  id uuid primary key default uuid_generate_v4(),
  influencer_id uuid not null references public.influencers(id) on delete cascade,
  store_id uuid not null references public.stores(id) on delete cascade,
  monthly_amount numeric(10,2) not null default 300,
  month date not null, -- أول يوم من الشهر المحتسب
  status text not null default 'pending', -- pending, paid
  created_at timestamptz not null default now(),
  unique(influencer_id, store_id, month)
);

create index idx_influencer_commissions_influencer on public.influencer_commissions(influencer_id);

alter table public.influencers enable row level security;
alter table public.influencer_commissions enable row level security;

create policy "influencers_select_own"
  on public.influencers for select
  using (profile_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "influencer_commissions_select_own"
  on public.influencer_commissions for select
  using (
    exists (select 1 from public.influencers i where i.id = influencer_id and i.profile_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- ----------------------------------------------------------------------------
-- 14. shared_blacklist
--   أخضر: return_count < 3 | برتقالي: return_count < 5 | أحمر: return_count >= 5
-- ----------------------------------------------------------------------------
create table public.shared_blacklist (
  customer_id uuid primary key references public.profiles(id) on delete cascade,
  return_count integer not null default 0,
  color blacklist_color not null default 'green',
  updated_at timestamptz not null default now()
);

alter table public.shared_blacklist enable row level security;

-- تظهر فقط للتجار الذين لديهم صلاحية القائمة السوداء (pro/enterprise) وللمشرف
create policy "blacklist_select_authorized_merchants"
  on public.shared_blacklist for select
  using (
    exists (
      select 1 from public.stores s
      where s.owner_id = auth.uid() and s.blacklist_enabled = true
    )
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- ----------------------------------------------------------------------------
-- 15. دوال حساب العمولة ومساعدة المرتجعات حسب الخطة (محسوبة مباشرة بـ SQL)
-- ----------------------------------------------------------------------------

-- هيكل العمولة: مبلغ ثابت + نسبة من قيمة المنتج، لكل طلب ناجح
create or replace function public.fn_commission_structure(p_plan plan_type)
returns table(fixed_fee numeric, percent_fee numeric) as $$
begin
  return query
    select
      case p_plan
        when 'free' then 35::numeric
        when 'basic' then 20::numeric
        when 'pro' then 12::numeric
        when 'enterprise' then 6::numeric
      end,
      case p_plan
        when 'free' then 0.03::numeric
        when 'basic' then 0.015::numeric
        when 'pro' then 0.008::numeric
        when 'enterprise' then 0.003::numeric
      end;
end;
$$ language plpgsql immutable;

-- نسبة مساعدة المرتجعات وسقف عدد المرتجعات المدعومة، لكل خطة
create or replace function public.fn_assistance_structure(p_plan plan_type)
returns table(percentage numeric, cap_count integer) as $$
begin
  return query
    select
      case p_plan
        when 'free' then 15::numeric
        when 'basic' then 30::numeric
        when 'pro' then 40::numeric
        when 'enterprise' then 50::numeric
      end,
      case p_plan
        when 'free' then 10
        when 'basic' then 13
        when 'pro' then 25
        when 'enterprise' then 34
      end;
end;
$$ language plpgsql immutable;

-- ----------------------------------------------------------------------------
-- 14.5 مُتتالية ومُشغّل لتوليد order_number تلقائياً (مثال: ORD-10432)
-- ----------------------------------------------------------------------------
create sequence public.order_number_seq start with 10000 increment by 1;

create or replace function public.fn_generate_order_number()
returns trigger as $$
begin
  if new.order_number is null then
    new.order_number := 'ORD-' || nextval('public.order_number_seq');
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_generate_order_number
  before insert on public.orders
  for each row execute function public.fn_generate_order_number();

-- ----------------------------------------------------------------------------
-- 15.0 مُشغّل: منع إنشاء طلب جديد عند تجاوز حد الخطة (10/150/300، وغير محدود للمؤسساتية)
--   يزيد عداد orders_used عند إنشاء الطلب مباشرة (وليس عند نجاحه)
-- ----------------------------------------------------------------------------
create or replace function public.fn_enforce_order_limit()
returns trigger as $$
declare
  v_plan plan_type;
  v_orders_used integer;
  v_orders_limit integer;
begin
  select plan, orders_used, orders_limit into v_plan, v_orders_used, v_orders_limit
    from public.stores where id = new.store_id;

  if v_plan <> 'enterprise' and v_orders_used >= v_orders_limit then
    raise exception 'تم تجاوز الحد الأقصى لعدد الطلبات ضمن الخطة الحالية (% طلب). يرجى ترقية الخطة.', v_orders_limit
      using errcode = 'P0001';
  end if;

  update public.stores set orders_used = orders_used + 1 where id = new.store_id;
  return new;
end;
$$ language plpgsql;

create trigger trg_enforce_order_limit
  before insert on public.orders
  for each row execute function public.fn_enforce_order_limit();

-- ----------------------------------------------------------------------------
-- 15.1 مُشغّل: حساب عمولة الطلب تلقائياً عند نجاحه (delivered)
--   يراعي خصم 50% للتجار المؤسسين الذهبيين/الفضيين
-- ----------------------------------------------------------------------------
create or replace function public.fn_calculate_order_commission()
returns trigger as $$
declare
  v_plan plan_type;
  v_fixed numeric;
  v_percent numeric;
  v_reduction numeric := 0;
begin
  if new.order_status = 'delivered'
     and (tg_op = 'INSERT' or old.order_status is distinct from 'delivered') then

    select plan into v_plan from public.stores where id = new.store_id;
    select fixed_fee, percent_fee into v_fixed, v_percent
      from public.fn_commission_structure(v_plan);

    select commission_reduction_percentage into v_reduction
      from public.founding_merchants where store_id = new.store_id;
    v_reduction := coalesce(v_reduction, 0);

    new.commission_amount := round(
      (v_fixed + v_percent * new.total_product_price) * (1 - v_reduction / 100), 2
    );
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_calculate_order_commission
  before insert or update on public.orders
  for each row execute function public.fn_calculate_order_commission();

-- ----------------------------------------------------------------------------
-- 15.2 مُشغّل: حساب مساعدة المرتجع تلقائياً عند التوثيق، وإضافته لرصيد المتجر
--   إن تجاوز عدد المرتجعات سقف الخطة، تُوثّق العملية دون مساعدة (refund_amount = 0)
-- ----------------------------------------------------------------------------
create or replace function public.fn_calculate_return_assistance()
returns trigger as $$
declare
  v_store_id uuid;
  v_plan plan_type;
  v_percentage numeric;
  v_cap integer;
  v_used_count integer;
begin
  select o.store_id into v_store_id from public.orders o where o.id = new.order_id;
  select plan, returns_assisted_count into v_plan, v_used_count
    from public.stores where id = v_store_id;
  select percentage, cap_count into v_percentage, v_cap
    from public.fn_assistance_structure(v_plan);

  new.assistance_percentage := v_percentage;

  if v_used_count < v_cap then
    new.refund_amount := round(new.return_shipping_cost * v_percentage / 100, 2);
    new.status := 'credited';
    update public.stores
      set balance = balance + new.refund_amount,
          returns_assisted_count = returns_assisted_count + 1
      where id = v_store_id;
  else
    new.refund_amount := 0;
    new.status := 'documented'; -- تجاوز سقف الخطة: يُوثّق المرتجع دون مساعدة
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_calculate_return_assistance
  before insert on public.returns
  for each row execute function public.fn_calculate_return_assistance();

-- ----------------------------------------------------------------------------
-- 15.3 مُشغّل: إضافة مكافأة إحالة التاجر (500 دج) كرصيد داخلي عند اعتمادها
--   يُستعمل هذا الرصيد حصراً لترقية أو تجديد الاشتراك، ولا يُصرف نقداً
-- ----------------------------------------------------------------------------
create or replace function public.fn_credit_merchant_referral_bonus()
returns trigger as $$
begin
  if new.status = 'credited'
     and (tg_op = 'INSERT' or old.status is distinct from 'credited') then
    update public.stores set balance = balance + new.bonus_amount
      where id = new.referrer_store_id;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_credit_merchant_referral_bonus
  after insert or update on public.merchant_referral_bonus
  for each row execute function public.fn_credit_merchant_referral_bonus();

-- ----------------------------------------------------------------------------
-- 15.4 دالة ومُشغّل (Trigger) لتحديث لون القائمة السوداء تلقائياً
-- ----------------------------------------------------------------------------
create or replace function public.fn_update_blacklist_color()
returns trigger as $$
begin
  if new.return_count >= 5 then
    new.color := 'red';
  elsif new.return_count < 3 then
    new.color := 'green';
  else
    new.color := 'orange'; -- يشمل 3 و 4
  end if;
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger trg_update_blacklist_color
  before insert or update on public.shared_blacklist
  for each row execute function public.fn_update_blacklist_color();

-- ----------------------------------------------------------------------------
-- 16. دالة عامة لتحديث updated_at تلقائياً (تُطبّق على الجداول ذات الحقل)
-- ----------------------------------------------------------------------------
create or replace function public.fn_set_updated_at()
returns trigger as $$
begin
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger trg_profiles_updated_at before update on public.profiles
  for each row execute function public.fn_set_updated_at();
create trigger trg_stores_updated_at before update on public.stores
  for each row execute function public.fn_set_updated_at();
create trigger trg_products_updated_at before update on public.products
  for each row execute function public.fn_set_updated_at();
create trigger trg_orders_updated_at before update on public.orders
  for each row execute function public.fn_set_updated_at();

-- ============================================================================
-- 17. Winner Radar — منتج إضافي داخل حساب التاجر (حصري لمستخدمي BOTSHOP-DZ)
--   الوصول الكامل: خطتا الاحترافية والمؤسساتية | 3 محاولات تجريبية لبقية الخطط
--   الوحدة 2 (فلتر الجدوى اللوجستية) مجانية وغير محدودة دائماً، وتُستعمل كبوابة
--   قرار أولى قبل استهلاك أي محاولة من محركي التحليل والمحتوى (المدعومين بالذكاء
--   الاصطناعي فعلياً، وهما فقط ما يُخصم من winner_radar_trial_remaining)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 17.1 suppliers_blackbook — قاعدة الموردين، تُدار حصرياً من المشرف
-- ----------------------------------------------------------------------------
create table public.suppliers_blackbook (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  phone text not null,
  wilaya text not null,
  niche text not null, -- مثال: تجميل، إلكترونيات، مدرسي
  notes text,
  is_active boolean not null default true,
  added_by uuid references public.profiles(id) on delete set null, -- المشرف الذي أضافه
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_blackbook_niche on public.suppliers_blackbook(niche);
create index idx_blackbook_wilaya on public.suppliers_blackbook(wilaya);

alter table public.suppliers_blackbook enable row level security;

-- القراءة: لأي تاجر مسجّل (نوع حساب تاجر) وللمشرف، فقط للصفوف النشطة
create policy "blackbook_select_merchants"
  on public.suppliers_blackbook for select
  using (
    (is_active = true and exists (
      select 1 from public.profiles p where p.id = auth.uid() and p.role in ('supplier','retailer','contracted')
    ))
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- الإضافة/التعديل/الحذف: للمشرف فقط
create policy "blackbook_modify_admin_only"
  on public.suppliers_blackbook for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

create trigger trg_blackbook_updated_at before update on public.suppliers_blackbook
  for each row execute function public.fn_set_updated_at();

-- ----------------------------------------------------------------------------
-- 17.2 winner_radar_logistics_checks — الوحدة 2: فلتر الجدوى اللوجستية
--   مجاني وغير محدود دائماً لكل التجار، بغض النظر عن الخطة
-- ----------------------------------------------------------------------------
create table public.winner_radar_logistics_checks (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  product_idea text,
  has_liquids boolean not null default false,
  is_oversized boolean not null default false, -- أكبر من 30 سم
  needs_sizing boolean not null default false, -- يحتاج مقاسات
  risk_level text not null default 'low', -- low / medium / high — تُحسب تلقائياً بمُشغّل
  created_at timestamptz not null default now()
);

create index idx_logistics_checks_store on public.winner_radar_logistics_checks(store_id);

alter table public.winner_radar_logistics_checks enable row level security;

create policy "logistics_checks_select_own"
  on public.winner_radar_logistics_checks for select
  using (
    exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

create policy "logistics_checks_insert_own"
  on public.winner_radar_logistics_checks for insert
  with check (exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

-- دالة ومُشغّل: حساب مستوى المخاطرة تلقائياً عند كل فحص
create or replace function public.fn_calculate_logistics_risk()
returns trigger as $$
begin
  if new.has_liquids then
    new.risk_level := 'high'; -- السوائل محفوفة بمخاطر رفض شركات التوصيل دائماً
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

create trigger trg_calculate_logistics_risk
  before insert on public.winner_radar_logistics_checks
  for each row execute function public.fn_calculate_logistics_risk();

-- ----------------------------------------------------------------------------
-- 17.3 winner_radar_requests — الوحدتان 1 و4 (محركا الذكاء الاصطناعي)
--   محكومتان بسقف المحاولات التجريبية لغير خطتي الاحترافية/المؤسساتية
-- ----------------------------------------------------------------------------
create table public.winner_radar_requests (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  request_type text not null check (request_type in ('ad_analyzer', 'content_generator')),
  input_text text not null,
  output_text text, -- تُملأ لاحقاً من طبقة التطبيق/n8n بعد استدعاء الذكاء الاصطناعي
  market_saturation_level text check (market_saturation_level in ('low','medium','high')), -- لطلبات ad_analyzer فقط، وصفي وليس رقماً مُختلَقاً
  created_at timestamptz not null default now()
);

create index idx_wr_requests_store on public.winner_radar_requests(store_id);

alter table public.winner_radar_requests enable row level security;

create policy "wr_requests_select_own"
  on public.winner_radar_requests for select
  using (
    exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

create policy "wr_requests_insert_own"
  on public.winner_radar_requests for insert
  with check (exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

-- دالة ومُشغّل: يمنع الاستخدام بعد نفاد المحاولات التجريبية لغير الخطط المؤهّلة،
-- ويخصم محاولة واحدة تلقائياً عند كل استخدام لغير خطتي pro/enterprise
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

create trigger trg_enforce_winner_radar_trial
  before insert on public.winner_radar_requests
  for each row execute function public.fn_enforce_winner_radar_trial();

-- ----------------------------------------------------------------------------
-- 17.4 winner_radar_sessions — محرك قرار الاختبار: يربط كل الوحدات لمنتج واحد
--   ويحسب صافي الربح والقرار النهائي (Go/Caution/Stop) تلقائياً بمُشغّل SQL
--   ملاحظة: نسبة المرتجعات وميزانية الإعلان تقديرات يُدخلها التاجر بنفسه،
--   وليست أرقاماً تدّعي المنصة معرفتها فعلياً — لا هلوسة إحصائية
-- ----------------------------------------------------------------------------
create table public.winner_radar_sessions (
  id uuid primary key default uuid_generate_v4(),
  store_id uuid not null references public.stores(id) on delete cascade,
  product_idea text not null,

  -- مدخلات حاسبة الربح الصافي (تقديرات التاجر الخاصة)
  purchase_price numeric(10,2),
  suggested_sale_price numeric(10,2),
  shipping_cost numeric(10,2),
  estimated_return_rate_pct numeric(5,2), -- تقدير التاجر الخاص، ليس متوسطاً فعلياً من المنصة
  estimated_ad_budget numeric(10,2),

  -- مخرجات محسوبة تلقائياً
  net_profit numeric(10,2),
  net_margin_pct numeric(5,2),
  verdict text check (verdict in ('go','caution','stop')), -- يُحسب تلقائياً، فارغ حتى اكتمال بيانات كافية

  -- روابط لسجلات الوحدات الأخرى ضمن نفس الجلسة
  logistics_check_id uuid references public.winner_radar_logistics_checks(id) on delete set null,
  ad_analysis_id uuid references public.winner_radar_requests(id) on delete set null,
  content_generation_id uuid references public.winner_radar_requests(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_wr_sessions_store on public.winner_radar_sessions(store_id);

alter table public.winner_radar_sessions enable row level security;

create policy "wr_sessions_select_own"
  on public.winner_radar_sessions for select
  using (
    exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid())
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

create policy "wr_sessions_modify_own"
  on public.winner_radar_sessions for all
  using (exists (select 1 from public.stores s where s.id = store_id and s.owner_id = auth.uid()));

create trigger trg_wr_sessions_updated_at before update on public.winner_radar_sessions
  for each row execute function public.fn_set_updated_at();

-- دالة ومُشغّل: يحسب صافي الربح والهامش والقرار النهائي تلقائياً عند أي إدخال/تعديل
-- عتبات القرار (10%/20% هامش، ومستويات المخاطرة) قابلة للتعديل لاحقاً حسب خبرتك التجارية،
-- وليست إحصائية مُدَّعاة — هي قواعد عمل داخلية فقط
create or replace function public.fn_calculate_winner_radar_verdict()
returns trigger as $$
declare
  v_logistics_risk text;
  v_market_saturation text;
begin
  -- 1) حساب صافي الربح والهامش (رياضيات بسيطة على مدخلات التاجر نفسه)
  new.net_profit := coalesce(new.suggested_sale_price,0) - coalesce(new.purchase_price,0)
                     - coalesce(new.shipping_cost,0)
                     - (coalesce(new.suggested_sale_price,0) * coalesce(new.estimated_return_rate_pct,0) / 100)
                     - coalesce(new.estimated_ad_budget,0);

  new.net_margin_pct := case when coalesce(new.suggested_sale_price,0) > 0
    then round((new.net_profit / new.suggested_sale_price) * 100, 2)
    else null end;

  -- 2) جلب نتائج الوحدات المرتبطة إن وُجدت
  if new.logistics_check_id is not null then
    select risk_level into v_logistics_risk
      from public.winner_radar_logistics_checks where id = new.logistics_check_id;
  end if;
  if new.ad_analysis_id is not null then
    select market_saturation_level into v_market_saturation
      from public.winner_radar_requests where id = new.ad_analysis_id;
  end if;

  -- 3) القرار النهائي: أحمر إن وُجد خطر جسيم، أصفر إن وُجدت مخاطرة متوسطة، أخضر إن كانت كل المؤشرات جيدة
  if v_logistics_risk = 'high' or (new.net_margin_pct is not null and new.net_margin_pct < 10) then
    new.verdict := 'stop';
  elsif v_logistics_risk = 'medium' or v_market_saturation = 'high'
        or (new.net_margin_pct is not null and new.net_margin_pct < 20) then
    new.verdict := 'caution';
  elsif new.logistics_check_id is not null and new.net_margin_pct is not null then
    new.verdict := 'go';
  else
    new.verdict := null; -- بيانات غير كافية بعد لإصدار قرار
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_calculate_winner_radar_verdict
  before insert or update on public.winner_radar_sessions
  for each row execute function public.fn_calculate_winner_radar_verdict();

-- ============================================================================
-- ملاحظات هامة قبل التنفيذ في Supabase:
-- 1. عمولة الطلب ومساعدة المرتجعات محسوبتان مباشرة بدوال ومُشغّلات SQL
--    (fn_calculate_order_commission عند وصول الطلب لحالة delivered،
--    fn_calculate_return_assistance عند توثيق مرتجع جديد). أي تعديل مستقبلي
--    على القيم يكون بتعديل fn_commission_structure / fn_assistance_structure فقط.
-- 2. رصيد stores.balance (مساعدة المرتجعات + مكافأة إحالة التجار 500 دج) هو
--    رصيد داخلي غير نقدي بالكامل، يُستعمل حصراً لترقية أو تجديد الاشتراك، ولا
--    يُصرف نقداً بأي حال — مطبَّق عبر المُشغّلات مباشرة عند الاعتماد.
-- 3. عمولة التاجر المتعاقد (agreed_commission) يحددها تاجر الجملة/التجزئة
--    بحرية تامة مع كل عقد. أما فائدة المنصة من العقد فرمزية وثابتة:
--    500 دج/الشهر لكل عقد نشط (عمود platform_monthly_fee + جدول
--    contract_platform_fees للفوترة الشهرية). آلية توليد فاتورة كل شهر تلقائياً
--    (عبر n8n أو Supabase Cron) تُحدَّد في خطوة الأتمتة لاحقاً.
-- 4. حدود الخطط (10 طلبات مدى الحياة، 150، 300، غير محدود) مطبَّقة مباشرة بمُشغّل
--    SQL (fn_enforce_order_limit) يمنع إدخال أي طلب جديد يتجاوز orders_limit،
--    ويرفع استثناءً (P0001) يجب على طبقة التطبيق التقاطه وعرض رسالة "رجاء ترقية
--    الخطة" للتاجر.
-- 5. نص العقد الشرعي (terms_text) يُدرَج كقالب من طبقة التطبيق، ويتطلب
--    مراجعة مختص شرعي قبل الإطلاق كما ورد في تعليماتك.
-- ============================================================================
