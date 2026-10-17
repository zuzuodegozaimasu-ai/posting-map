// Stripe からの通知（支払い完了・更新・解約・支払い失敗）を受けて、契約状態をデータベースに反映する
// Supabase ダッシュボードで「Verify JWT」をオフにしてデプロイ（Stripe の署名で本物か確認します）
import Stripe from "npm:stripe@22.6.0";
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  httpClient: Stripe.createFetchHttpClient(),
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

async function saveSubscription(sub: Stripe.Subscription) {
  const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
  let userId = sub.metadata?.user_id;
  if (!userId) {
    const { data } = await admin.from("billing_customers").select("user_id").eq("stripe_customer_id", customerId).maybeSingle();
    userId = data?.user_id;
  }
  if (!userId) { console.error("user_id が分からない契約です", sub.id); return; }

  const plan = sub.metadata?.plan === "team" ? "team" : "personal";
  // 新しいAPIでは契約期間の終わりは明細（items）側に入っている
  // deno-lint-ignore no-explicit-any
  const end = (sub.items?.data?.[0] as any)?.current_period_end ?? (sub as any).current_period_end ?? null;

  const { error } = await admin.from("subscriptions").upsert({
    id: sub.id,
    user_id: userId,
    plan,
    group_id: plan === "team" && sub.metadata?.group_id ? sub.metadata.group_id : null,
    status: sub.status,
    current_period_end: end ? new Date(end * 1000).toISOString() : null,
    stripe_customer_id: customerId,
    updated_at: new Date().toISOString(),
  });
  if (error) throw error;
}

Deno.serve(async (req) => {
  const signature = req.headers.get("Stripe-Signature");
  if (!signature) return new Response("署名がありません", { status: 400 });
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature, WEBHOOK_SECRET, undefined, cryptoProvider);
  } catch (e) {
    console.error("署名の確認に失敗", e);
    return new Response("署名が正しくありません", { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.mode === "subscription" && s.subscription && s.payment_status !== "unpaid") {
          const subId = typeof s.subscription === "string" ? s.subscription : s.subscription.id;
          await saveSubscription(await stripe.subscriptions.retrieve(subId));
        }
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
      case "customer.subscription.paused":
      case "customer.subscription.resumed":
        await saveSubscription(event.data.object as Stripe.Subscription);
        break;
      case "invoice.paid":
      case "invoice.payment_failed": {
        // deno-lint-ignore no-explicit-any
        const inv = event.data.object as any;
        const subId = inv.parent?.subscription_details?.subscription ?? inv.subscription;
        if (subId) await saveSubscription(await stripe.subscriptions.retrieve(typeof subId === "string" ? subId : subId.id));
        break;
      }
    }
  } catch (e) {
    console.error("反映に失敗", event.type, e);
    return new Response("処理に失敗しました", { status: 500 }); // Stripe が自動で再送します
  }
  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});
