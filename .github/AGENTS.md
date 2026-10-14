# .github/ (AGENTS.md)

`workflows/ci.yml` runs three jobs: `build` (shellcheck, the `ox-setup` action with the pins and
`libpq-dev`, `dune build`, `dune test`, with a PostgreSQL service), `e2e-stack` (the full stack
script, with its log uploaded), and `obj-magic`, the shared reusable workflow from `infra`.

- The pin list is in dependency order and must match `dune-project`; a new org dependency gets its
  pin in the same commit. The `hl-copy-api-types` pin names the `hl-copy-web` repository.
- Keep the `concurrency` block.
- Check a run with one `gh run list --limit 1`, and at most one `gh run watch <id> --exit-status`.
