# AGENTS.md (hl-copy-api)

## Purpose

The HTTP API of the copy-trading platform: wallet sign-in, agent key generation and approval,
builder fee approval, follow management, and proxies for leaders and follower status. It stores
follows and agents in PostgreSQL and writes the files the copy engine reads. It submits approvals
to the simulator or testnet only, and refuses any exchange URL on the mainnet host.

Workspace-wide rules, the repository map and the CI model are in
`../oxcaml-claude-skills/AGENTS.md`. Read that first.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `hl_copy_api` library: wallet signatures, sessions, challenges, approvals, agents, follows, storage (`Store_pg`, `Store_memory`), the server ([lib/AGENTS.md](lib/AGENTS.md)) |
| `bin/` | The `hl-copy-api` executable and its flags ([bin/AGENTS.md](bin/AGENTS.md)) |
| `migrations/` | SQL migrations, embedded into the binary and applied at startup |
| `tools/` | `dev_wallet`, a throwaway-key signer for local runs (not installed) |
| `test/` | In-process tests: login, approvals, follows, store conformance, restart ([test/AGENTS.md](test/AGENTS.md)) |
| `scripts/` | `curl-flow.sh` (the HTTP flow by hand) and `e2e-stack.sh` (the whole stack) |
| `.github/` | CI workflow ([.github/AGENTS.md](.github/AGENTS.md)) |
| `README.md` | Endpoints, storage, the agent key design, the end-to-end run, CI pins |

## Build and test

From this repository, inside the workspace:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @hl-copy-api/all @hl-copy-api/runtest
```

For parallel work give the build its own directory, relative to the workspace root:
`DUNE_BUILD_DIR=_build-hl-copy-api` in front of the same command.

Standalone, with the published dependencies:

```sh
opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git
opam install . --deps-only --with-test
dune build && dune test
```

PostgreSQL tests use `HL_COPY_TEST_DATABASE_URL` when it is set, otherwise pg-async's throwaway
cluster, which needs the PostgreSQL server binaries installed locally.

Format only this repository, after the tests pass:
`dune build --root .. @hl-copy-api/fmt --auto-promote`. Never run `dune fmt` at the workspace root.

## Conventions

- Core style: `open! Core`, an `.mli` for every module, labelled arguments, expect tests and
  Base_quickcheck properties.
- SQL lives only in `store_pg.ml` and `migrations/`. Every write is keyed and idempotent.
- A schema change is a new migration file. Never edit a migration that has run anywhere.
- The store interface has two implementations and one conformance suite; a new method goes in
  the suite first.
- Wallet signatures are checked against `eth_account` vectors. Keep those vectors in the tests.
- Odoc on every public value; comments at every pinned limit, saying what and why.
- No `Obj.magic`. The obj-magic job in CI enforces it.

## Dependencies and dependents

- Depends on `pg-async`, `hl-copy-core`, `hl-copy-api-types` (from `../hl-copy-web`), `hl-client`,
  `hl-protocol`, `hl-leaderboard` (proxy), `exchange-core` and `fixed-decimal`. The pin order is in
  `.github/workflows/ci.yml`; the `hl-copy-api-types` pin names the `hl-copy-web` repository.
- Writes the follow and key files that `../hl-copy-engine` reads, and reads its `/status`.
- The web app in `../hl-copy-web` calls this API; its live smoke test runs against it.
- Deployed by `../infra` (`compose/`, `charts/`).
- Spec: `../specs/repos/hl-copy-api.md`; the design is in `../specs/design/copytrading.md`, with
  `../specs/adr/0007-agent-keys-not-custody.md` and `../specs/adr/0009-postgres-replaceable-store.md`.

## CI

`.github/workflows/ci.yml` has three jobs. `build` runs `shellcheck scripts/*.sh`, the `ox-setup`
action (with `pg-async` and the other pins, and `libpq-dev`), then `dune build` and `dune test`,
with a PostgreSQL service. `e2e-stack` runs `scripts/e2e-stack.sh` against the simulator, the
leaderboard, the engine and the web smoke test, and uploads its log. `obj-magic` calls the shared
reusable workflow from `infra`.

Check a run with one `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- The switch's cryptokit has ChaCha20 and HMAC but no AEAD. Agent keys are sealed
  encrypt-then-MAC and checked against Python test vectors; do not change the scheme without a
  new format version.
- Two approvals signed in the same millisecond share a nonce, and the simulator rejects the second.
  Make nonces strictly increase within a process.
- `open Hl_protocol` hides a local `Ws_message` module. Qualify the name or rename the local.
- `Clock_ns.every` fires at once. Pass `~start:(Clock_ns.after span)` for a delayed first tick.
- `User_fill` drops `builderFee` and `liquidation`. A server that decodes `/exchange` with
  `Exchange_request` loses the builder field, so use the full type when you need it.
- Any `*.hyperliquid.xyz` exchange URL is refused at startup, so test configuration must never use one.

## Where to read more

- `README.md`, `../specs/repos/hl-copy-api.md`, `../specs/design/copytrading.md`
- `../oxcaml-claude-skills/AGENTS.md`, `../oxcaml-claude-skills/GOTCHAS.md`
- Skills: `../oxcaml-claude-skills/skills/async-http-websocket` (the HTTP and websocket server),
  `../oxcaml-claude-skills/skills/banking-standards` only if the change touches money handling

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Approve an agent or sign an exchange action against a mainnet URL, or remove the URL guard.
- Publish, tag or release.
- Commit credentials. The master key comes from `HL_COPY_MASTER_KEY`, and the database URL from
  `DATABASE_URL` or the `PG*` variables, in the environment only.
- Print the master key, agent keys, session tokens or signatures.
