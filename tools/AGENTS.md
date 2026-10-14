# tools/ (AGENTS.md)

`dev_wallet`, a signer for local runs and the web app's smoke test. It takes a throwaway key from
`HL_COPY_WALLET_KEY` and prints `address`, `personal-sign` and `sign-typed-data` results. It is
not installed and refuses mainnet typed data.

- Never give it a key that holds funds. Keys come from the environment only.
