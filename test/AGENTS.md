# test/ (AGENTS.md)

In-process tests of the server: login, agent and builder fee approval, follows, CORS, rate limits,
metrics, the websocket against a signature-checking `hl-sim`, the store conformance suite over both
stores, migrations, and a restart that rebuilds the engine's files.

- The store suite runs against both `Store_pg` and `Store_memory`; add new store behaviour there.
- Expect output of signatures is pinned to `eth_account` vectors; regenerate them only in a
  scratch virtualenv, never in the shared switch.
- Run from the repository root with `opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-api/runtest`.
