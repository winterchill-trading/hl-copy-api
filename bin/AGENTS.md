# bin/ (AGENTS.md)

The `hl-copy-api` executable. Flags: `-port`, `-exchange-url`, `-leaderboard-url`, `-engine-url`,
`-database-url`, `-memory-store`, `-state-dir`, `-config-dir`, `-allow-origin`, `-builder` and
`-builder-fee`. The full list is in the root `README.md`.

Build and run from the repository root: `opam exec --switch 5.2.0+ox -- dune exec hl-copy-api -- -help`.

Rules that matter here:

- `-memory-store` runs without PostgreSQL; use it for local runs and tests only.
- Keep flags and the README table in step.
