# lib/ (AGENTS.md)

The `hl_copy_api` library: `Wallet_signature` (personal_sign and typed-data recovery), `Session`
and `Challenge` (stateless HMAC tokens, in-memory single-use nonces), `Venue` and `Approvals`
(the mainnet guard and approval offers), `Agents` (key rotation), `Follows` (table records and
engine files), `Leaders` and `Engine_status` (proxies), `Rate_limiter`, `Metrics`, `Server`.
`gen/` is the build-time generator that embeds `migrations/`.

Build from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-api/all`.

Rules that matter here:

- Writes go to the database first, then to the files. A failed store write answers 503.
- Sessions and challenges are not persisted, by design. Do not add a table for them.
- The approval must match the pending offer and recover to the session's wallet before it is
  posted. Keep both checks when you touch `Approvals`.
