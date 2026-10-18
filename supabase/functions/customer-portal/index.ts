// 契約の確認・解約・カード変更の画面（Stripe カスタマーポータル）を開く
// Supabase ダッシュボードで「Verify JWT」をオフにしてデプロイ（中でログインを確認します）
import Stripe from "npm:stripe@22.6.0";
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const APP_URL = Deno.env.get("APP_URL") ?? "https://zuzuodegozaimasu-ai.github.io/posting-map/";
const cors = (req: Request) => ({
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": req.headers.get("Access-Control-Request-Headers") ?? "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
});
let CORS: Record<string, string> = {};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  CORS = cors(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    return await handle(req);
  } catch (e) {
    console.error(e);
    return json({ error: "決済サーバーでエラーが起きました：" + (e instanceof Error ? e.message : String(e)) }, 500);
  }
});

async function handle(req: Request): Promise<Response> {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) return json({ error: "STRIPE_SECRET_KEY が Supabase の Secrets に登録されていません" }, 500);
  const stripe = new Stripe(key, { httpClient: Stripe.createFetchHttpClient() });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth, error } = await admin.auth.getUser(token);
  if (error || !auth.user) return json({ error: "ログインし直してください" }, 401);

  const { data: bc } = await admin.from("billing_customers").select("stripe_customer_id").eq("user_id", auth.user.id).maybeSingle();
  if (!bc) return json({ error: "まだ有料プランの契約がありません" }, 404);

  const portal = await stripe.billingPortal.sessions.create({ customer: bc.stripe_customer_id, return_url: APP_URL, locale: "ja" });
  return json({ url: portal.url });
}
