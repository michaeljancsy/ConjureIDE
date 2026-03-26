import type { Env } from "./types";
import { signToken, createTokenPayload } from "./token";

/**
 * POST /activate
 * Body: { transaction_id: string, machine_id: string }
 *
 * After Paddle checkout completes, the app sends the transaction ID.
 * We resolve it to a subscription via the Paddle API, store it in D1,
 * and return a signed token.
 */
export async function handleActivate(
  request: Request,
  env: Env
): Promise<Response> {
  const body = (await request.json()) as {
    transaction_id?: string;
    machine_id?: string;
  };

  if (!body.transaction_id || !body.machine_id) {
    return Response.json(
      { error: "transaction_id and machine_id required" },
      { status: 400 }
    );
  }

  try {
    // Resolve transaction → subscription via Paddle API
    const txn = await fetchPaddleTransaction(body.transaction_id, env);
    if (!txn) {
      return Response.json(
        { error: "Transaction not found" },
        { status: 404 }
      );
    }

    const subscriptionId = txn.subscription_id;
    if (!subscriptionId) {
      return Response.json(
        { error: "Transaction has no subscription" },
        { status: 400 }
      );
    }

    // Fetch full subscription details
    const sub = await fetchPaddleSubscription(subscriptionId, env);
    if (!sub) {
      return Response.json(
        { error: "Subscription not found" },
        { status: 404 }
      );
    }

    // Upsert subscription in D1
    await env.DB.prepare(
      `INSERT INTO subscriptions (id, email, paddle_customer_id, status, current_period_end, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
       ON CONFLICT(id) DO UPDATE SET
         status = excluded.status,
         current_period_end = excluded.current_period_end,
         updated_at = datetime('now')`
    )
      .bind(
        sub.id,
        sub.customer_email,
        sub.customer_id,
        sub.status,
        sub.current_billing_period?.ends_at ?? new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()
      )
      .run();

    // Record activation
    await env.DB.prepare(
      `INSERT INTO activations (subscription_id, machine_id, activated_at)
       VALUES (?, ?, datetime('now'))`
    )
      .bind(subscriptionId, body.machine_id)
      .run();

    // Sign and return token
    const periodEnd = sub.current_billing_period?.ends_at ?? new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
    const payload = createTokenPayload(
      subscriptionId,
      sub.customer_email,
      sub.status,
      periodEnd
    );
    const token = await signToken(payload, env);

    return Response.json({ token });
  } catch (err) {
    console.error("Activate error:", err);
    return Response.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

interface PaddleTransaction {
  id: string;
  subscription_id: string | null;
  customer_id: string;
  status: string;
}

interface PaddleSubscription {
  id: string;
  customer_id: string;
  customer_email: string;
  status: string;
  current_billing_period: {
    starts_at: string;
    ends_at: string;
  } | null;
}

async function fetchPaddleTransaction(
  transactionId: string,
  env: Env
): Promise<PaddleTransaction | null> {
  const res = await fetch(
    `${env.PADDLE_API_BASE}/transactions/${transactionId}`,
    {
      headers: {
        Authorization: `Bearer ${env.PADDLE_API_KEY}`,
        "Content-Type": "application/json",
      },
    }
  );
  if (!res.ok) return null;
  const json = (await res.json()) as { data: PaddleTransaction };
  return json.data;
}

async function fetchPaddleSubscription(
  subscriptionId: string,
  env: Env
): Promise<PaddleSubscription | null> {
  const res = await fetch(
    `${env.PADDLE_API_BASE}/subscriptions/${subscriptionId}`,
    {
      headers: {
        Authorization: `Bearer ${env.PADDLE_API_KEY}`,
        "Content-Type": "application/json",
      },
    }
  );
  if (!res.ok) return null;
  const json = (await res.json()) as { data: PaddleSubscription };
  return json.data;
}
