// WayForPay webhook handler
// Приймає Service Callback від WayForPay після успішної/відхиленої оплати
// Перевіряє HMAC-MD5 підпис, знаходить юзера за email і нараховує credits

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createHash, createHmac } from "node:crypto";

const MERCHANT_LOGIN = "t_me_f0bca";
const SECRET = Deno.env.get("WAYFORPAY_SECRET") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

// Мапа: amount (UAH) → скільки credits нараховувати
// 790 → 1, 2844 → 4, 6320 → 10
function creditsForAmount(amount: number): number {
  const map: Record<number, number> = { 790: 1, 2844: 4, 6320: 10 };
  return map[Math.round(amount)] || 0;
}

function md5(str: string): string {
  return createHash("md5").update(str).digest("hex");
}
function hmacMd5(key: string, str: string): string {
  return createHmac("md5", key).update(str).digest("hex");
}

function verifySignature(p: any): boolean {
  if (!SECRET) return false;
  // Згідно WayForPay docs: merchantSignature формується по полях
  // merchantAccount;orderReference;amount;currency;authCode;cardPan;transactionStatus;reasonCode
  const fields = [
    p.merchantAccount,
    p.orderReference,
    p.amount,
    p.currency,
    p.authCode || "",
    p.cardPan || "",
    p.transactionStatus,
    p.reasonCode,
  ].join(";");
  const expected = hmacMd5(SECRET, fields);
  return expected === p.merchantSignature;
}

function buildResponse(orderReference: string): Response {
  const time = Math.floor(Date.now() / 1000);
  const status = "accept";
  const responseSignature = hmacMd5(SECRET, [orderReference, status, time].join(";"));
  return new Response(
    JSON.stringify({
      orderReference,
      status,
      time,
      responseSignature,
    }),
    { headers: { "Content-Type": "application/json" } },
  );
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: { "Access-Control-Allow-Origin": "*" } });
  }
  if (req.method !== "POST") {
    return new Response("Only POST", { status: 405 });
  }

  let payload: any = {};
  try {
    const contentType = req.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      payload = await req.json();
    } else {
      // WayForPay може слати form-urlencoded
      const text = await req.text();
      try {
        payload = JSON.parse(text);
      } catch {
        const params = new URLSearchParams(text);
        payload = Object.fromEntries(params.entries());
      }
    }
  } catch (e) {
    console.error("Parse error:", e);
    return new Response("Bad payload", { status: 400 });
  }

  console.log("WayForPay payload:", JSON.stringify(payload));

  // Перевіряємо merchantAccount
  if (payload.merchantAccount !== MERCHANT_LOGIN) {
    console.warn("Wrong merchantAccount:", payload.merchantAccount);
    return new Response("Wrong merchant", { status: 403 });
  }

  // Перевірка підпису
  if (!verifySignature(payload)) {
    console.warn("Bad signature for order:", payload.orderReference);
    return new Response("Bad signature", { status: 403 });
  }

  // Тільки успішні платежі додають кредити
  if (payload.transactionStatus !== "Approved") {
    console.log("Skip non-approved:", payload.transactionStatus);
    return buildResponse(payload.orderReference || "");
  }

  const email = (payload.email || payload.clientEmail || "").toLowerCase().trim();
  const amount = parseFloat(payload.amount);
  const credits = creditsForAmount(amount);

  if (!email || !credits) {
    console.warn("Missing email or unknown amount:", { email, amount });
    return buildResponse(payload.orderReference || "");
  }

  const supa = createClient(SUPABASE_URL, SERVICE_KEY);

  // Idempotency: запис у payments по wayforpay_order_id (унікальний)
  const { data: existing } = await supa
    .from("payments")
    .select("id, status")
    .eq("wayforpay_order_id", payload.orderReference)
    .maybeSingle();

  if (existing && existing.status === "success") {
    console.log("Already processed:", payload.orderReference);
    return buildResponse(payload.orderReference);
  }

  // Знаходимо юзера за email через auth.users (тільки service_role може)
  const { data: { users }, error: listErr } = await supa.auth.admin.listUsers();
  if (listErr) {
    console.error("listUsers:", listErr);
    return new Response("DB error", { status: 500 });
  }
  const user = users.find((u: any) => (u.email || "").toLowerCase() === email);
  if (!user) {
    console.warn("User not found:", email);
    // Все одно записуємо платіж щоб не пропав
    await supa.from("payments").insert({
      user_id: null,
      amount,
      qty: credits,
      currency: payload.currency || "UAH",
      wayforpay_order_id: payload.orderReference,
      status: "success",
      raw_payload: payload,
    } as any);
    return buildResponse(payload.orderReference);
  }

  // Нараховуємо credits атомарно
  const { data: profile, error: profErr } = await supa
    .from("profiles")
    .select("credits")
    .eq("id", user.id)
    .single();
  if (profErr) {
    console.error("Profile fetch:", profErr);
    return new Response("DB error", { status: 500 });
  }
  const newCredits = (profile.credits || 0) + credits;
  await supa.from("profiles").update({ credits: newCredits }).eq("id", user.id);

  // Запис у payments
  await supa.from("payments").insert({
    user_id: user.id,
    amount,
    qty: credits,
    currency: payload.currency || "UAH",
    wayforpay_order_id: payload.orderReference,
    status: "success",
    raw_payload: payload,
  });

  console.log(`Added ${credits} credits to ${email}, new balance: ${newCredits}`);

  return buildResponse(payload.orderReference);
});
