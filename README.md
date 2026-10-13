# hl-copy-api

The HTTP API of the Hyperliquid copy-trading platform: wallet login, per-user agent keys
and their approval, builder fee approval, follows, leaders proxied from
[hl-leaderboard](https://github.com/winterchill-trading/hl-leaderboard), and the user's
status from [hl-copy-engine](https://github.com/winterchill-trading/hl-copy-engine). The
web app is [hl-copy-web](https://github.com/winterchill-trading/hl-copy-web), which owns
the shared request and response types (`Api_types`, opam package `hl-copy-api-types`).

**Simulator and testnet only.** The server refuses any exchange URL under
`hyperliquid.xyz` at startup and only builds approvals for `hyperliquidChain: "Testnet"`.
It never asks for or sees a user's wallet key.

Library `hl-copy-api` (module `Hl_copy_api`) and binary `hl-copy-api`. Approved agent
keys go to `Hl_copy_core.Key_store`, which the engine reads with the same master key.

## Running

```sh
export HL_COPY_MASTER_KEY=$(openssl rand -hex 32)   # keep it: it opens every stored agent key
hl-sim -port 3000 -strict-signatures &
hl-copy-api -port 8080 -exchange-url http://localhost:3000 \
  -leaderboard-url http://localhost:8090 -engine-url http://localhost:8070 \
  -state-dir ./state -config-dir ./state/configs \
  -allow-origin http://localhost:8000
```

`hl-copy-api -help` lists every flag (builder address and fee, session lifetime, rate
limits, public URL for the sign-in message). Logs go to stderr, one line per request.

## Endpoints

Bodies are JSON in the `Api_types` shapes. "auth" means `Authorization: Bearer <token>`
from `/auth/verify`.

| Route | Auth | Body -> reply |
| --- | --- | --- |
| `POST /auth/challenge` | | `{address}` -> `{message, nonce, expires_at}` |
| `POST /auth/verify` | | `{address, nonce, signature}` (`nonce` optional: the newest challenge) -> `{token, address, expires_at}` |
| `POST /agent/new` | yes | -> `{approve_agent, approve_builder_fee?, typed_data: {approve_agent, approve_builder_fee?}}` |
| `POST /agent/approved` | yes | `{signature, approve_agent?}` -> agent status |
| `POST /agent/revoke` | yes | -> agent status; running follows are paused |
| `POST /builder-fee` | yes | `{signature, approve_builder_fee?}` -> agent status |
| `GET /follows` | yes | -> list of follows |
| `POST /follows` | yes | `{leader, scale, caps}` -> follow (201); needs an approved agent |
| `GET /follows/:id` | yes | -> follow |
| `PATCH /follows/:id` | yes | `{state?: "running" or "paused", scale?, caps?}` -> follow |
| `DELETE /follows/:id` | yes | -> follow, now `stopped` |
| `POST /follows/:id/pause`, `/resume`, `/stop` | yes | -> follow |
| `GET /leaders`, `GET /leaders/:address` | | from hl-leaderboard; 503 when none is configured |
| `GET /me` | yes | -> `{address, account_value, total_pnl, agent?, follows}` |
| `GET /ws?token=<token>` | token | websocket: `{"type":"me"}` on connect and every 15 s, `{"type":"follow"}` on changes, `{"type":"fill"}` per new fill of the account |
| `GET /healthz`, `GET /metrics` | | liveness; Prometheus text |

Errors are `{"error": "..."}` with 400, 401, 404, 409, 413, 429, 502 or 503. Every reply
carries CORS headers for the allowed origins, and `OPTIONS` answers preflights. Requests
are rate limited per client IP (600 per minute, 30 on `/auth/*`, by default).

### curl

`scripts/curl-flow.sh` walks the whole browser flow with curl and a throwaway key,
signing with `eth_account` where the browser would use the wallet:

```sh
python3 -m venv /tmp/venv && /tmp/venv/bin/pip install eth-account
PYTHON=/tmp/venv/bin/python API=http://localhost:8080 scripts/curl-flow.sh
```

Step by step:

```sh
API=http://localhost:8080
curl -s -X POST $API/auth/challenge -H 'content-type: application/json' \
  -d '{"address":"0xcf03dd0a894ef79cb5b601a43c4b25e3ae4c67ed"}'
# {"message":"localhost:8080 wants you to sign in with your Ethereum account:\n0xcF03...","nonce":"81018cb7e4d6b302",...}
# Sign "message" with personal_sign, then:
curl -s -X POST $API/auth/verify -H 'content-type: application/json' \
  -d '{"address":"0xcf03...","nonce":"81018cb7e4d6b302","signature":"0x..."}'
# {"token":"0xcf03...<expiry>.<mac>","address":"0xcf03...","expires_at":...}
curl -s -X POST $API/agent/new -H "authorization: Bearer $TOKEN"
# Sign typed_data.approve_agent with eth_signTypedData_v4, then:
curl -s -X POST $API/agent/approved -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"signature":"0x..."}'
# {"agent_address":"0xe7c4...","agent_name":"hl-copy valid_until 1807343157720","approved":true,...}
curl -s -X POST $API/follows -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"leader":"0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf",
       "scale":{"kind":"multiplier","value":0.5},
       "caps":{"max_leverage":3,"max_notional_per_symbol":5000,"max_daily_loss":500,
               "allowlist":["BTC"],"min_order_notional":10}}'
curl -s -X PATCH $API/follows/$ID -H "authorization: Bearer $TOKEN" -d '{"state":"paused"}'
curl -s -X DELETE $API/follows/$ID -H "authorization: Bearer $TOKEN"
curl -s $API/me -H "authorization: Bearer $TOKEN"
```

## How it works

- **Login.** The challenge follows the Sign-In with Ethereum (EIP-4361) layout, with a
  random single-use nonce that expires after five minutes (kept in memory). `/auth/verify`
  recovers the `personal_sign` signer (EIP-191, Keccak and secp256k1 recovery from
  hl-client) and issues a stateless token `<address>.<issued_ms>.<expires_ms>.<mac>`,
  HMAC-SHA256 under a key derived from the master key. Nothing is stored per session.
- **Agents.** `/agent/new` generates a fresh secp256k1 key, seals it into the keystore
  as pending and offers `approveAgent` for a named agent `hl-copy valid_until <ms>`
  (179 days ahead, inside the documented 180). An unapproved offer younger than an hour
  is offered again instead of minting another key. `/agent/approved` checks that the
  signed action is the pending one (the browser may change only `signatureChainId`),
  that it recovers to the logged-in wallet, posts it to `/exchange`, and marks the agent
  active; a previous active agent becomes revoked. Agent addresses are never reused.
  Every nonce the server hands out for one wallet is distinct, even within a millisecond.
- **Builder fee.** Offered with the agent when `-builder` is set, signed by the wallet,
  submitted the same way.
- **Follows.** Each follow is a record in `<state>/follows/<id>.sexp` and, while running or
  paused, an `Hl_copy_core.Follower_config` file `<configs>/<follower>-<leader>.sexp` that
  the engine watches (`paused true` when paused, removed on stop). Web caps of `0` mean no
  cap and an empty allowlist copies every coin.
- **Leaders** come from `hl-leaderboard serve` (cached 10 s) and are reshaped into
  `Api_types`; the score is the leaderboard score times 100, clamped to 0 to 100.
- **Status.** `/me` combines the account value from `clearinghouseState` with per-follow
  pnl and positions from the engine's `/status`, read leniently (see
  `lib/engine_status.mli` for the accepted shape); without an engine it reports zeros.

### Agent keys at rest

Unapproved offers live in memory only (a restart means asking for a new offer). Once the
exchange accepts `approveAgent`, the key is sealed into `Hl_copy_core.Key_store`:
`<state>/agents/<account>.key`, mode 0600, the account's current agent (address, name,
created, valid until, ciphertext, nonce, tag). Approving another agent replaces it;
`/agent/revoke` deletes it. The engine opens it with the same `HL_COPY_MASTER_KEY`:

```ocaml
let%bind store = Hl_copy_core.Key_store.create ~state_dir () in   (* master key from env *)
match Hl_copy_core.Key_store.get store ~account with
| Ok (Some (_entry, hex)) -> Hl_client.Signing.Private_key.of_hex hex
| Ok None -> (* no approved agent: do not trade *)
| Error _ -> (* wrong master key or tampered file *)
```

Sealing: cryptokit 1.16 on the switch has no AEAD mode, so `Key_store` composes ChaCha20
and HMAC-SHA256 as encrypt-then-MAC, with a fresh 24-byte random nonce per key that
derives the ChaCha20 key (no key and nonce pair repeats) and the account and agent
addresses as associated data. Moving to ChaCha20-Poly1305 or AES-GCM is a TODO for when
the switch has a cryptokit with AEAD.

## Tests

`dune test` runs everything in-process: login, agent and builder fee approval, follows,
CORS, rate limits, metrics and the websocket against an hl-sim that verifies every
signature, with throwaway keys made in the test. Wallet signatures (`personal_sign` and
the approval typed data) are pinned against `eth_account`, and the leaders proxy runs
against a real `hl-leaderboard serve`.

## CI pins

fixed-decimal, exchange-core, order-book, exchange-core-engine, hl-protocol, parquet,
market-data, price-anchor, venue-net, hl-client, binance-protocol, mm-core,
binance-client, hl-sim, hl-copy-core, hl-leaderboard, and `hl-copy-api-types` from the
hl-copy-web repository (only that package, so the web app's dependencies stay out).
