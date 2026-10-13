#!/usr/bin/env bash
# Walks the browser's flow with curl against a running hl-copy-api: wallet login,
# agent approval, a follow, then /me. The wallet is a throwaway key, signed with
# eth_account in place of a browser wallet.
#
#   PYTHON=<python with eth-account> API=http://localhost:8080 scripts/curl-flow.sh
#
# Point the API at hl-sim (or testnet) only; the API refuses mainnet anyway.
set -euo pipefail

PYTHON=${PYTHON:-python3}
API=${API:-http://localhost:8080}
LEADER=${LEADER:-0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf}
# A fixed throwaway key: only ever used against the simulator.
KEY=${KEY:-0x$(printf '%064x' 4660)}

json() { "$PYTHON" -I -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }

ADDR=$("$PYTHON" -I -c "from eth_account import Account; print(Account.from_key('$KEY').address.lower())")
echo "wallet $ADDR"

CHALLENGE=$(curl -sf -X POST "$API/auth/challenge" -H 'content-type: application/json' \
  -d "{\"address\":\"$ADDR\"}")
SIGNATURE=$("$PYTHON" -I -c "
import json, sys
from eth_account import Account
from eth_account.messages import encode_defunct
message = json.loads(sys.argv[1])['message']
print('0x' + Account.sign_message(encode_defunct(text=message), sys.argv[2]).signature.hex())
" "$CHALLENGE" "$KEY")
NONCE=$(echo "$CHALLENGE" | json "['nonce']")
TOKEN=$(curl -sf -X POST "$API/auth/verify" -H 'content-type: application/json' \
  -d "{\"address\":\"$ADDR\",\"nonce\":\"$NONCE\",\"signature\":\"$SIGNATURE\"}" | json "['token']")
echo "logged in"

OFFER=$(curl -sf -X POST "$API/agent/new" -H "authorization: Bearer $TOKEN")
AGENT_SIGNATURE=$("$PYTHON" -I -c "
import json, sys
from eth_account import Account
from eth_account.messages import encode_typed_data
typed = json.loads(sys.argv[1])['typed_data']['approve_agent']
print('0x' + Account.sign_message(encode_typed_data(full_message=typed), sys.argv[2]).signature.hex())
" "$OFFER" "$KEY")
curl -sf -X POST "$API/agent/approved" -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d "{\"signature\":\"$AGENT_SIGNATURE\"}"
echo

curl -sf -X POST "$API/follows" -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d "{\"leader\":\"$LEADER\",\"scale\":{\"kind\":\"multiplier\",\"value\":0.5},
       \"caps\":{\"max_leverage\":3,\"max_notional_per_symbol\":5000,\"max_daily_loss\":500,
                 \"allowlist\":[\"BTC\"],\"min_order_notional\":10}}"
echo
curl -sf "$API/me" -H "authorization: Bearer $TOKEN"
echo
