# scripts/ (AGENTS.md)

`curl-flow.sh` walks the HTTP flow by hand (challenge, verify, agent, approval, follow). `e2e-stack.sh`
starts the simulator, the leaderboard, this API and the engine, runs the flow and the web smoke
test, and writes a log. It takes `DATABASE_URL` or starts a throwaway PostgreSQL cluster.

- Both scripts must pass `shellcheck`; CI runs it.
- The e2e script takes minutes even on a warm cache; run it when a change touches the flow.
