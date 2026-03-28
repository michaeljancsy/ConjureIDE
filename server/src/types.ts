export interface Env {
  DB: D1Database;
  PADDLE_API_KEY: string;
  PADDLE_API_BASE: string;
  PADDLE_WEBHOOK_SECRET: string;
  ED25519_PRIVATE_KEY: string; // base64-encoded 32-byte seed
}

export interface TokenPayload {
  sub: string;       // Paddle subscription ID
  email: string;
  status: string;    // "active", "paused", "canceled", "past_due"
  valid_until: string; // ISO 8601
  issued_at: string;   // ISO 8601
  product: string;     // "conjuredsp"
}

export interface Subscription {
  id: string;
  email: string;
  paddle_customer_id: string;
  status: string;
  current_period_end: string;
  created_at: string;
  updated_at: string;
}
