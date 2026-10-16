# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- `algo` on `POST /follows` and `PATCH /follows/:id`: execution-algos' short form,
  validated by execution-algos (`Exec_algo_spec`), stored (migration 0002) and written
  into the engine's follower config. Follows return `algo` (absent for immediate) and
  `execution`, the engine's cost report from `/status` (absent without one): requests and
  replies without them are unchanged.
- `/leaders` carries `universe` (persistence, selection statistics, integrity counts) and
  the new summary fields; `/leaders/:address` carries the leader's persistence row,
  selection statistics and integrity flags.
- `scripts/e2e-stack.sh` checks the universe block and a TWAP round trip through the
  engine.

### Changed

- Depends on `execution-algos`; CI pins it and `backtest-stats`.
