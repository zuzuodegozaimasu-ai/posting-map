// 有料プランの決済画面（Stripe Checkout）を作る
// 呼び出し: アプリからログイン中のユーザーが POST { plan: "personal" | "team", group_id?: string }
// Supabase ダッシュボードで「Verify JWT」をオフにしてデプロイ（中でログインを確認します）
import Stripe from "npm:stripe@22.6.0";
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  httpClient: Stripe.createFetchHttpClient(),
});
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const APP_URL = Deno.env.get("APP_URL") ?? "https://zuzuodegozaimasu-ai.github.io/posting-map/";
const PRICES: Record<string, string | undefined> = {
  personal: Deno.env.get("STRIPE_PRICE_PERSONAL"),
  team: Deno.env.get("STRIPE_PRICE_TEAM"),
};
const cors = {
  "Access-Control-Allow-Origin": new URL(APP_URL).origin,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function randomLetters(n: number) {
  const a = "abcdefghijklmnopqrstuvwxyz";
  return Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => a[b % 26]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POSTで呼び出してください" }, 405);

  // ログイン中のユーザーを確認
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth, error: authErr } = await admin.auth.getUser(token);
  if (authErr || !auth.user) return json({ error: "ログインし直してください" }, 401);
  const user = auth.user;

  const { plan, group_id } = await req.json().catch(() => ({}));
  const price = PRICES[plan];
  if (!price) return json({ error: "プランの指定が正しくありません" }, 400);

  if (plan === "team") {
    if (!group_id) return json({ error: "グループを指定してください" }, 400);
    const { data: m } = await admin.from("members").select("role").eq("group_id", group_id).eq("user_id", user.id).maybeSingle();
    if (!m || m.role !== "owner") return json({ error: "チームプランにできるのは、グループの作成者だけです" }, 403);
    const { data: t } = await admin.rpc("is_team", { gid: group_id });
    if (t) return json({ error: "このグループはすでにチームプランです" }, 409);
  } else {
    const { data: p } = await admin.rpc("is_pro", { uid: user.id });
    if (p) return json({ error: "すでに個人プランに加入しています" }, 409);
  }

  // Stripe の顧客を用意（2回目以降は同じ顧客を使う）
  let { data: bc } = await admin.from("billing_customers").select("stripe_customer_id").eq("user_id", user.id).maybeSingle();
  if (!bc) {
    const customer = await stripe.customers.create({ email: user.email, metadata: { user_id: user.id } });
    await admin.from("billing_customers").insert({ user_id: user.id, stripe_customer_id: customer.id });
    bc = { stripe_customer_id: customer.id };
  }

  const meta = { user_id: user.id, plan, group_id: plan === "team" ? group_id : "" };
  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer: bc.stripe_customer_id,
    line_items: [{ price, quantity: 1 }],
    client_reference_id: user.id,
    metadata: meta,
    subscription_data: { metadata: meta },
    locale: "ja",
    success_url: `${APP_URL}?checkout=success`,
    cancel_url: `${APP_URL}?checkout=cancel`,
    integration_identifier: `posting-map-${plan}-${randomLetters(8)}`,
  });
  return json({ url: session.url });
});
