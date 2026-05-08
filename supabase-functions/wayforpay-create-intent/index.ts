// wayforpay-create-intent
// Edge Function що генерує підписаний WayForPay payload для виклику з кабінету.
// Авторизує юзера через JWT, бере його email/імʼя з profile, формує payload з orderReference
// = "user_<uuid>_<timestamp>", підписує HMAC-MD5 і повертає на фронт.
// Фронт викликає Wayforpay.run(payload) — відкривається iframe з ВЖЕ заповненими полями
// які юзер не може змінити.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createHmac } from "node:crypto";

const MERCHANT_LOGIN = "t_me_f0bca";
const MERCHANT_DOMAIN = "mysenko-kateryna.github.io";
const SECRET = Deno.env.get("WAYFORPAY_SECRET") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const RETURN_URL = "https://mysenko-kateryna.github.io/enps-service/screen-4-cabinet.html?payment=return";

const PACKAGES: Record<number, { amount: number; name: string }> = {
  1: { amount: 790, name: "eNPS — 1 опитування" },
  4: { amount: 2844, name: "eNPS — 4 опитування" },
  10: { amount: 6320, name: "eNPS — 10 опитувань" },
};

function hmacMd5(key: string, str: string): string {
  return createHmac("md5", key).update(str).digest("hex");
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("POST only", { status: 405, headers: corsHeaders });
  }

  // Авторизація — Bearer JWT
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) {
    return new Response(JSON.stringify({ error: "Not authenticated" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supa = createClient(SUPABASE_URL, SERVICE_KEY);
  const { data: { user }, error: authErr } = await supa.auth.getUser(jwt);
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: "Invalid auth" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Тіло запиту: { qty: 1 | 4 | 10 }
  let body: any = {};
  try { body = await req.json(); } catch (_) {}
  const qty = parseInt(body.qty, 10);
  const pkg = PACKAGES[qty];
  if (!pkg) {
    return new Response(JSON.stringify({ error: "Invalid qty" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Беремо профіль для імені
  const { data: profile } = await supa
    .from("profiles")
    .select("name")
    .eq("id", user.id)
    .single();
  const fullName = ((profile as any)?.name || "").trim();
  const parts = fullName.split(" ");
  const firstName = parts[0] || "";
  const lastName = parts.slice(1).join(" ") || "";

  const orderReference = `user_${user.id}_${Date.now()}`;
  const orderDate = Math.floor(Date.now() / 1000);
  const productName = pkg.name;
  const productPrice = pkg.amount;
  const productCount = 1;

  // Підпис WayForPay:
  // merchantAccount;merchantDomainName;orderReference;orderDate;amount;currency;productName1[,...];productCount1[,...];productPrice1[,...]
  const signFields = [
    MERCHANT_LOGIN,
    MERCHANT_DOMAIN,
    orderReference,
    orderDate,
    pkg.amount,
    "UAH",
    productName,
    productCount,
    productPrice,
  ].join(";");
  const merchantSignature = hmacMd5(SECRET, signFields);

  const payload = {
    merchantAccount: MERCHANT_LOGIN,
    merchantDomainName: MERCHANT_DOMAIN,
    merchantTransactionSecureType: "AUTO",
    merchantSignature,
    orderReference,
    orderDate,
    amount: pkg.amount,
    currency: "UAH",
    productName: [productName],
    productPrice: [productPrice],
    productCount: [productCount],
    clientFirstName: firstName,
    clientLastName: lastName,
    clientEmail: user.email || "",
    language: "UK",
    serviceUrl: `${SUPABASE_URL}/functions/v1/wayforpay-webhook`,
    returnUrl: RETURN_URL,
  };

  return new Response(JSON.stringify(payload), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
