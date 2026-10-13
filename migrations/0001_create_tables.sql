-- hl-copy-api's own tables in its own database (hl_copy). No other service reads them;
-- the engine gets its inputs as files the API writes from these rows.

-- One row per (follower, leader); stopped follows stay for the dashboard.
CREATE TABLE follows (
  id text PRIMARY KEY,                -- "<follower>-<leader>"
  follower text NOT NULL,
  leader text NOT NULL,
  scale_mode text NOT NULL
    CHECK (scale_mode IN ('equity_ratio', 'multiplier', 'fixed_notional')),
  scale_value double precision,       -- the multiplier or the USD notional
  max_leverage double precision NOT NULL,          -- 0 means no cap, as in the web form
  max_notional_per_symbol double precision NOT NULL,
  max_daily_loss double precision NOT NULL,
  allowlist text[] NOT NULL,                       -- empty copies every coin
  min_order_notional double precision NOT NULL,
  state text NOT NULL CHECK (state IN ('running', 'paused', 'stopped')),
  created_ms bigint NOT NULL,
  updated_ms bigint NOT NULL,
  CHECK ((scale_mode = 'equity_ratio') = (scale_value IS NULL))
);

CREATE INDEX follows_by_follower ON follows (follower, created_ms, id);

-- Each account's current agent key, sealed by the API's master key exactly as in the
-- key store file (encrypt-then-MAC; the database never sees the plaintext key).
-- Times are integer nanoseconds so the file rewritten from a row is byte-identical.
CREATE TABLE agents (
  account text PRIMARY KEY,
  agent_address text NOT NULL,
  agent_name text NOT NULL,
  created_ns bigint NOT NULL,
  valid_until_ns bigint,
  ciphertext bytea NOT NULL,
  nonce bytea NOT NULL CHECK (octet_length(nonce) = 24),
  tag bytea NOT NULL CHECK (octet_length(tag) = 32),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE builder_fee_approvals (
  account text NOT NULL,
  builder text NOT NULL,
  approved_at timestamptz NOT NULL,
  PRIMARY KEY (account, builder)
);
