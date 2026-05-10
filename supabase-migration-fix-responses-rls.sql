-- Міграція: дозволити анонімам надсилати відповіді на активні опитування
-- Дата: 2026-05-09
-- Проблема: співробітники (без логіну) отримують RLS violation коли пробують submit

drop policy if exists "Anyone submits to active survey" on public.responses;
create policy "Anyone submits to active survey" on public.responses
  for insert
  to anon, authenticated
  with check (
    exists (
      select 1 from public.surveys s
      where s.id = survey_id and s.status = 'active'
    )
  );

-- Опціонально: дозволити власнику survey також зробити SELECT власних responses
-- (вже є "Owner sees responses" — нічого не міняємо)
