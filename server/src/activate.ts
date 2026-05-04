import type { Env } from "./types";

/**
 * POST /activate
 *
 * TEMPORARILY DISABLED.
 *
 * The previous implementation (see git history pre-2.0.0) trusted any
 * transaction_id Paddle confirmed exists, with no proof-of-ownership check —
 * a known forgery vector (Asana 1214321752057687). No transaction IDs are
 * distributed yet, so we reject everything until the proof-of-ownership check
 * lands. To restore: re-implement with a verified Paddle session token (or
 * server-side checkout origination) before unblocking.
 */
export async function handleActivate(
  _request: Request,
  _env: Env
): Promise<Response> {
  console.log("Activation rejected (kill-switch enabled)");
  return Response.json(
    { error: "Activation temporarily unavailable" },
    { status: 503 }
  );
}
