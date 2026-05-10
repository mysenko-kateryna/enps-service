-- Міграція: захист credits від прямих UPDATE з клієнта (фікс C1 з audit-report.md)
-- Дата: 2026-05-09
-- Проблема: користувач через DevTools міг виконати
--   sb.from('profiles').update({credits: 9999}).eq('id', user.id)
-- і отримати безкоштовні опитування. RLS policy "Users update own profile"
-- дозволяла оновлення всіх колонок без обмежень.
--
-- Рішення: тригер BEFORE UPDATE блокує зміну credits для всіх крім service_role/postgres,
-- + RPC consume_credit() через SECURITY DEFINER для атомарного списання.

-- ============================================================================
-- 1. Тригер що блокує прямий UPDATE колонки credits
-- ============================================================================

create or replace function public.profiles_block_credits_change()
returns trigger
language plpgsql
as $$
begin
  -- Спрацьовує тільки якщо credits фактично змінюється
  if new.credits is distinct from old.credits then
    -- service_role (webhook) і postgres (міграції/RPC SECURITY DEFINER) - дозволено
    -- authenticated, anon - заборонено
    if current_user not in ('postgres', 'supabase_admin', 'service_role', 'supabase_auth_admin') then
      raise exception 'Колонка credits захищена. Використовуйте RPC consume_credit() або add_credits().'
        using errcode = 'insufficient_privilege';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_block_credits_change on public.profiles;

-- BEFORE UPDATE OF credits — тригер активується лише коли credits згадується у SET
create trigger profiles_block_credits_change
  before update of credits on public.profiles
  for each row
  execute function public.profiles_block_credits_change();

-- ============================================================================
-- 2. RPC consume_credit() — атомарне списання -1 кредиту
-- ============================================================================
-- Використання з фронту:
--   const { data, error } = await sb.rpc('consume_credit');
--   if (error) alert(error.message);
--   else state.credits = data.credits;

create or replace function public.consume_credit()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_credits int;
  new_credits int;
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  -- Lock рядка щоб уникнути race у двох табах
  select credits into current_credits
  from public.profiles
  where id = uid
  for update;

  if current_credits is null then
    raise exception 'Profile not found' using errcode = 'P0002';
  end if;

  if current_credits < 1 then
    raise exception 'Недостатньо кредитів. Поповніть баланс щоб активувати опитування.'
      using errcode = 'P0001';
  end if;

  new_credits := current_credits - 1;
  update public.profiles set credits = new_credits where id = uid;

  return jsonb_build_object(
    'success', true,
    'credits', new_credits,
    'consumed', 1
  );
end;
$$;

revoke execute on function public.consume_credit() from public;
revoke execute on function public.consume_credit() from anon;
grant execute on function public.consume_credit() to authenticated;

-- ============================================================================
-- 3. RPC add_credits(amount) — для webhook (під service_role)
-- ============================================================================
-- Поки webhook прямо update робить (service_role обходить тригер), але
-- цей RPC може знадобитись у майбутньому для refund/admin додавання

create or replace function public.add_credits(target_user_id uuid, amount int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  new_credits int;
begin
  if amount <= 0 then
    raise exception 'amount must be positive' using errcode = 'P0001';
  end if;

  update public.profiles
  set credits = credits + amount
  where id = target_user_id
  returning credits into new_credits;

  if new_credits is null then
    raise exception 'Profile not found for user_id %', target_user_id using errcode = 'P0002';
  end if;

  return jsonb_build_object('success', true, 'credits', new_credits, 'added', amount);
end;
$$;

revoke execute on function public.add_credits(uuid, int) from public;
revoke execute on function public.add_credits(uuid, int) from anon;
revoke execute on function public.add_credits(uuid, int) from authenticated;
grant execute on function public.add_credits(uuid, int) to service_role;

-- ============================================================================
-- 4. Перевірка що працює (виконати після міграції щоб переконатись)
-- ============================================================================
-- Спроба з SQL Editor (postgres role — має пройти):
--   update public.profiles set credits = credits where id = 'YOUR_UUID';
--
-- Спроба з клієнта (authenticated — має фейлити з помилкою):
--   sb.from('profiles').update({credits: 999}).eq('id', user.id)
--   → expected error: "Колонка credits захищена..."
--
-- Виклик RPC з клієнта (має повернути новий баланс):
--   sb.rpc('consume_credit')
--   → expected: { success: true, credits: N-1, consumed: 1 }
