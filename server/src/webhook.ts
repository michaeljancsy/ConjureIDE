import type { Env } from "./types";

/**
 * POST /webhooks/paddle
 *
 * Receives Paddle Billing webhook events. Validates the signature,
 * then upserts subscription status in D1.
 *
 * Key events:
 * - subscription.created
 * - subscription.updated
 * - subscription.canceled
 * - subscription.past_due
 * - transaction.completed
 */
export async function handleWebhook(
  request: Request,
  env: Env
): Promise<Response> {
  const body = await request.text();

  // Validate Paddle webhook signature
  const signature = request.headers.get("Paddle-Signature");
  if (!signature) {
    return new Response("Missing signature", { status: 401 });
  }

  const isValid = await verifyPaddleSignature(body, signature, env.PADDLE_WEBHOOK_SECRET);
  if (!isValid) {
    return new Response("Invalid signature", { status: 401 });
  }

  const event = JSON.parse(body) as PaddleWebhookEvent;
  console.log(`Webhook: ${event.event_type}`, event.data?.id);

  switch (event.event_type) {
    case "subscription.created":
    case "subscription.updated":
    case "subscription.canceled":
    case "subscription.past_due":
      await handleSubscriptionEvent(event, env);
      break;
    case "transaction.completed":
      // Transaction events are handled by /activate — log only
      console.log("Transaction completed:", event.data?.id);
      break;
    default:
      console.log("Unhandled event type:", event.event_type);
  }

  return new Response("OK", { status: 200 });
}

interface PaddleWebhookEvent {
  event_type: string;
  data: {
    id: string;
    customer_id?: string;
    status?: string;
    current_billing_period?: {
      starts_at: string;
      ends_at: string;
    };
    [key: string]: unknown;
  };
}

async function handleSubscriptionEvent(
  event: PaddleWebhookEvent,
  env: Env
): Promise<void> {
  const sub = event.data;
  const periodEnd = sub.current_billing_period?.ends_at ??
    new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

  await env.DB.prepare(
    `INSERT INTO subscriptions (id, email, paddle_customer_id, status, current_period_end, created_at, updated_at)
     VALUES (?, '', ?, ?, ?, datetime('now'), datetime('now'))
     ON CONFLICT(id) DO UPDATE SET
       status = excluded.status,
       current_period_end = excluded.current_period_end,
       paddle_customer_id = excluded.paddle_customer_id,
       updated_at = datetime('now')`
  )
    .bind(
      sub.id,
      sub.customer_id ?? "",
      sub.status ?? "unknown",
      periodEnd
    )
    .run();
}

/**
 * Verify Paddle webhook signature (ts=timestamp;h1=hmac).
 */
async function verifyPaddleSignature(
  body: string,
  signatureHeader: string,
  secret: string
): Promise<boolean> {
  try {
    // Parse "ts=...;h1=..." format
    const parts: Record<string, string> = {};
    for (const part of signatureHeader.split(";")) {
      const [key, value] = part.split("=");
      if (key && value) parts[key] = value;
    }

    const ts = parts["ts"];
    const h1 = parts["h1"];
    if (!ts || !h1) return false;

    // Compute HMAC-SHA256 of "ts:body"
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );

    const message = `${ts}:${body}`;
    const sig = await crypto.subtle.sign(
      "HMAC",
      key,
      new TextEncoder().encode(message)
    );

    const expectedHex = Array.from(new Uint8Array(sig))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    return expectedHex === h1;
  } catch {
    return false;
  }
}
