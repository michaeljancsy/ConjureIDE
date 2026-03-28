import type { Env } from "./types";
import { signToken, createTokenPayload, verifyToken } from "./token";

/**
 * POST /verify
 * Body: { token: string, machine_id: string }
 *
 * The app sends its cached token. We extract the subscription ID,
 * look it up in D1 for the current status, and return a fresh token.
 */
export async function handleVerify(
  request: Request,
  env: Env
): Promise<Response> {
  const body = (await request.json()) as {
    token?: string;
    machine_id?: string;
  };

  if (!body.token || !body.machine_id) {
    return Response.json(
      { error: "token and machine_id required" },
      { status: 400 }
    );
  }

  try {
    // Verify the token signature and extract payload
    const payload = await verifyToken(body.token, env);
    if (!payload || !payload.sub) {
      return Response.json(
        { error: "Invalid or tampered token" },
        { status: 401 }
      );
    }

    // Look up subscription in D1
    const row = await env.DB.prepare(
      "SELECT id, email, status, current_period_end FROM subscriptions WHERE id = ?"
    )
      .bind(payload.sub)
      .first<{
        id: string;
        email: string;
        status: string;
        current_period_end: string;
      }>();

    if (!row) {
      return Response.json(
        { error: "Subscription not found" },
        { status: 404 }
      );
    }

    // Issue fresh token with current status
    const freshPayload = createTokenPayload(
      row.id,
      row.email,
      row.status,
      row.current_period_end
    );
    const freshToken = await signToken(freshPayload, env);

    return Response.json({ token: freshToken });
  } catch (err) {
    console.error("Verify error:", err);
    return Response.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}
