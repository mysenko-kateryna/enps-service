-- Міграція C2: дозволити orphan-записи у payments коли webhook не може знайти користувача
-- Дата: 2026-05-09
-- Проблема: payments.user_id NOT NULL ламає INSERT коли клієнт оплатив з email який
-- відрізняється від акаунта (або без акаунта). Webhook робить INSERT з user_id=null —
-- падає на constraint violation, платіж "зникає".
-- Рішення: DROP NOT NULL + ADD unmatched_email колонка для відстеження.
-- claim_orphan_payments() вже підхоплює orphan-записи коли клієнт логіниться.

ALTER TABLE public.payments ALTER COLUMN user_id DROP NOT NULL;

-- Зберігаємо email з payload щоб адмін бачив orphan-записи в одному місці
ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS unmatched_email text;

-- Індекс для адмін-оглядів орфанів
CREATE INDEX IF NOT EXISTS payments_orphan_idx
  ON public.payments (created_at DESC)
  WHERE user_id IS NULL;
