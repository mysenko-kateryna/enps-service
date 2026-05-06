-- Міграція: додає необов'язкове поле team у surveys
-- Виконати один раз у Supabase SQL Editor

ALTER TABLE public.surveys ADD COLUMN IF NOT EXISTS team text;

-- Індекс щоб findPreviousSurvey був швидким коли стане багато опитувань
CREATE INDEX IF NOT EXISTS idx_surveys_user_company_team
  ON public.surveys (user_id, lower(company), lower(team));
