-- ============================================
-- eNPS сервіс: схема БД для Supabase
-- HR. Час діяти! · © Катерина Мисенко
-- ============================================

-- 1. ПРОФІЛІ (розширення auth.users)
create table if not exists public.profiles (
  id uuid references auth.users(id) on delete cascade primary key,
  email text not null,
  name text,
  company text,
  avatar_url text,
  credits integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 2. ОПИТУВАННЯ
create table if not exists public.surveys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade not null,
  title text not null,
  company text,
  status text not null default 'draft',
  survey_date date,
  deadline date,
  closed_at timestamptz,
  employee_count integer,
  segment_options jsonb not null default '[]',
  segment_required boolean not null default false,
  ask_segment boolean not null default true,
  include_reason boolean not null default true,
  reason_required boolean not null default true,
  reason_question text,
  intro_text text,
  thank_you_text text,
  extra_questions jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint surveys_status_check check (status in ('draft','active','paused','completed'))
);

-- 3. ВІДПОВІДІ (анонімні, без user_id)
create table if not exists public.responses (
  id uuid primary key default gen_random_uuid(),
  survey_id uuid references public.surveys(id) on delete cascade not null,
  score smallint not null check (score >= 0 and score <= 10),
  segment text,
  comment text,
  extras jsonb not null default '[]',
  created_at timestamptz not null default now()
);

-- 4. ПЛАТЕЖІ (для wayforpay webhooks)
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade not null,
  amount numeric(10,2) not null,
  qty integer not null,
  currency text not null default 'UAH',
  wayforpay_order_id text unique,
  status text not null default 'pending',
  raw_payload jsonb,
  created_at timestamptz not null default now(),
  constraint payments_status_check check (status in ('pending','success','failed','refunded'))
);

-- ============================================
-- ІНДЕКСИ
-- ============================================
create index if not exists responses_survey_id_idx on public.responses(survey_id);
create index if not exists responses_created_at_idx on public.responses(created_at desc);
create index if not exists surveys_user_id_idx on public.surveys(user_id);
create index if not exists surveys_status_idx on public.surveys(status);
create index if not exists payments_user_id_idx on public.payments(user_id);

-- ============================================
-- ТРИГЕРИ
-- ============================================

-- Авто-оновлення updated_at
create or replace function public.handle_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.handle_updated_at();

drop trigger if exists surveys_updated_at on public.surveys;
create trigger surveys_updated_at before update on public.surveys
  for each row execute function public.handle_updated_at();

-- Авто-створення профілю при реєстрації
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email, name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email, '@', 1))
  );
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================
alter table public.profiles enable row level security;
alter table public.surveys enable row level security;
alter table public.responses enable row level security;
alter table public.payments enable row level security;

-- PROFILES: користувач бачить/редагує тільки свій профіль
drop policy if exists "Users see own profile" on public.profiles;
create policy "Users see own profile" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "Users update own profile" on public.profiles;
create policy "Users update own profile" on public.profiles
  for update using (auth.uid() = id);

-- SURVEYS: HR керує своїми опитуваннями
drop policy if exists "Users see own surveys" on public.surveys;
create policy "Users see own surveys" on public.surveys
  for select using (auth.uid() = user_id);

drop policy if exists "Users insert own surveys" on public.surveys;
create policy "Users insert own surveys" on public.surveys
  for insert with check (auth.uid() = user_id);

drop policy if exists "Users update own surveys" on public.surveys;
create policy "Users update own surveys" on public.surveys
  for update using (auth.uid() = user_id);

drop policy if exists "Users delete own surveys" on public.surveys;
create policy "Users delete own surveys" on public.surveys
  for delete using (auth.uid() = user_id);

-- SURVEYS: будь-хто може прочитати АКТИВНЕ опитування за лінком (для співробітника)
drop policy if exists "Anyone reads active surveys" on public.surveys;
create policy "Anyone reads active surveys" on public.surveys
  for select using (status = 'active');

-- RESPONSES: HR бачить відповіді на свої опитування
drop policy if exists "Owner sees responses" on public.responses;
create policy "Owner sees responses" on public.responses
  for select using (
    exists (select 1 from public.surveys s where s.id = survey_id and s.user_id = auth.uid())
  );

-- RESPONSES: будь-хто (анонім) може надіслати відповідь на АКТИВНЕ опитування
drop policy if exists "Anyone submits to active survey" on public.responses;
create policy "Anyone submits to active survey" on public.responses
  for insert with check (
    exists (select 1 from public.surveys s where s.id = survey_id and s.status = 'active')
  );

-- PAYMENTS: користувач бачить свої платежі
drop policy if exists "Users see own payments" on public.payments;
create policy "Users see own payments" on public.payments
  for select using (auth.uid() = user_id);

-- ============================================
-- ГОТОВО
-- ============================================
-- Перевірити: select * from public.profiles;
-- Має бути порожньо (поки нема юзерів)
