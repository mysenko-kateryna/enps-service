-- Функція claim_orphan_payments(): шукає осиротілі оплати (без user_id)
-- з тим самим email що у поточного юзера, привʼязує їх до юзера і нараховує credits.
-- Юзер викликає її після логіну/реєстрації через supabase.rpc("claim_orphan_payments").

CREATE OR REPLACE FUNCTION public.claim_orphan_payments()
RETURNS TABLE(total_credits int, payments_claimed int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  user_email text;
  total_qty int := 0;
  payment_count int := 0;
BEGIN
  -- Email поточного юзера
  SELECT lower(trim(email)) INTO user_email FROM auth.users WHERE id = auth.uid();
  IF user_email IS NULL OR user_email = '' THEN
    RETURN QUERY SELECT 0, 0;
    RETURN;
  END IF;

  -- Привʼязуємо всі осиротілі оплати з цим email до юзера
  WITH claimed AS (
    UPDATE public.payments p
    SET user_id = auth.uid()
    WHERE p.user_id IS NULL
      AND p.status = 'success'
      AND lower(trim(coalesce(p.raw_payload->>'email', p.raw_payload->>'clientEmail', ''))) = user_email
    RETURNING qty
  )
  SELECT coalesce(sum(qty), 0)::int, count(*)::int
  INTO total_qty, payment_count
  FROM claimed;

  -- Нараховуємо credits на профіль
  IF total_qty > 0 THEN
    UPDATE public.profiles
    SET credits = coalesce(credits, 0) + total_qty
    WHERE id = auth.uid();
  END IF;

  RETURN QUERY SELECT total_qty, payment_count;
END;
$$;

-- Дозволити authenticated юзерам викликати функцію
GRANT EXECUTE ON FUNCTION public.claim_orphan_payments() TO authenticated;
