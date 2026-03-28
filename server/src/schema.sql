-- D1 SQLite schema for ConjureDSP subscription API

CREATE TABLE IF NOT EXISTS subscriptions (
    id TEXT PRIMARY KEY,                -- Paddle subscription ID (e.g., "sub_abc123")
    email TEXT NOT NULL DEFAULT '',
    paddle_customer_id TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',  -- active, paused, canceled, past_due
    current_period_end TEXT NOT NULL,       -- ISO 8601 timestamp
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS activations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id TEXT NOT NULL REFERENCES subscriptions(id),
    machine_id TEXT NOT NULL,
    activated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_activations_subscription ON activations(subscription_id);
