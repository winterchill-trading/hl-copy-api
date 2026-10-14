#!/usr/bin/env bash
# The whole copy-trading stack on the simulator, driven the way a browser drives it:
#
#   hl-sim (3 leaders, 40 noise traders, strict signatures, seeded)
#   hl-leaderboard collect + rank + serve against the simulator
#   hl-copy-api (builder fee on, state in PostgreSQL), hl-copy-engine (agent keys from
#   the API's key store)
#
# then, with a throwaway wallet made here (never printed): challenge, personal_sign,
# verify, agent offer, approveAgent signed as eth_signTypedData_v4, approved, builder fee,
# follow a simulated leader with Equity_ratio and caps, wait FOLLOW_S seconds, and check:
#
#   - /me shows positions that track the leader within one lot (plus the $10 minimum
#     order the engine will not go below);
#   - /ws pushed follow and fill events;
#   - pause cancels the follow's orders and stops new ones; stop removes the follower
#     config;
#   - the engine's journal of the follow replays to the same outputs.
#
# It prints a summary (orders, fills, lag, slippage, pnl). With SMOKE=1 (the default when
# node and hl-copy-web are present) it also runs hl-copy-web's smoke/live.js against this
# API with a second throwaway wallet. Every process is stopped on exit; logs stay in
# LOG_DIR.
#
# Assumed layout: hl-copy-api next to its siblings in one dune workspace (a directory with
# a dune-workspace file), so dune builds every binary from source:
#
#   <root>/hl-copy-api <root>/hl-copy-engine <root>/hl-leaderboard <root>/hl-sim ...
#
# Or, when HL_SIM, HL_LEADERBOARD, HL_COPY_API, HL_COPY_ENGINE and DEV_WALLET name built
# executables (as CI does), nothing is built.
#
# Environment: WORKSPACE (<root>), OPAM_SWITCH (5.2.0+ox), DUNE_BUILD_DIR
# (<root>/_build-hl-copy-api-e2e), SEED (7), WARMUP_S (20: trading before the
# leaderboard is collected), FOLLOW_S (90), TRACK_WAIT_S (60), RESYNC_S (5), LEADER
# (leader 0, a trend follower), SIM_PORT (3570), LEADERBOARD_PORT (8590), API_PORT
# (8580), ENGINE_PORT (9970), DATABASE_URL (unset: a throwaway cluster on PG_PORT, 5590,
# from PG_BINDIR or pg_config), LOG_DIR (a temporary directory), SMOKE (1 or 0), WEB_JS
# (hl-copy-web's compiled main.bc.js), WEB_DIR (hl-copy-web's checkout).
#
# Simulator only: hl-sim on loopback, throwaway keys from openssl. The API and the engine
# refuse mainnet URLs, and the wallet tool refuses typed data for Hyperliquid Mainnet.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
switch="${OPAM_SWITCH:-5.2.0+ox}"
seed="${SEED:-7}"
warmup_s="${WARMUP_S:-20}"
follow_s="${FOLLOW_S:-90}"
track_wait_s="${TRACK_WAIT_S:-60}"
resync_s="${RESYNC_S:-5}"
leader="${LEADER:-0x1eade50000000000000000000000000000000000}"
sim_port="${SIM_PORT:-3570}"
lb_port="${LEADERBOARD_PORT:-8590}"
api_port="${API_PORT:-8580}"
engine_port="${ENGINE_PORT:-9970}"
pg_port="${PG_PORT:-5590}"
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hl-copy-stack.XXXXXX")}"
mkdir -p "$log_dir"
state="$log_dir/state"
configs="$log_dir/state/configs"
journal="$log_dir/journal"
mkdir -p "$state" "$configs" "$journal"

say() { echo "e2e-stack: $*" >&2; }

pids=()
stop_pg() { :; }
cleanup() {
  local code=$?
  for ((i = ${#pids[@]} - 1; i >= 0; i--)); do
    kill "${pids[$i]}" 2>/dev/null || true
    wait "${pids[$i]}" 2>/dev/null || true
  done
  stop_pg
  if ((code != 0)); then
    for f in sim leaderboard api engine ws; do
      if [[ -s "$log_dir/$f.log" ]]; then
        echo "---- last lines of $f.log" >&2
        tail -n 15 "$log_dir/$f.log" >&2
      fi
    done
    say "FAILED (exit $code); logs in $log_dir"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  say "FAIL: $*"
  exit 1
}

ports=("$sim_port" "$lb_port" "$api_port" "$engine_port")
if [[ -z "${DATABASE_URL:-}" ]]; then ports+=("$pg_port"); fi
for port in "${ports[@]}"; do
  if (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    fail "port $port is in use; set SIM_PORT, LEADERBOARD_PORT, API_PORT, ENGINE_PORT or PG_PORT"
  fi
done

# ---- Binaries

if [[ -n "${HL_SIM:-}" && -n "${HL_LEADERBOARD:-}" && -n "${HL_COPY_API:-}" &&
  -n "${HL_COPY_ENGINE:-}" && -n "${DEV_WALLET:-}" ]]; then
  sim_exe="$HL_SIM" lb_exe="$HL_LEADERBOARD" api_exe="$HL_COPY_API"
  engine_exe="$HL_COPY_ENGINE" wallet_exe="$DEV_WALLET"
else
  if [[ ! -f "$root/dune-workspace" ]]; then
    fail "$root has no dune-workspace (see the header of $0), or set HL_SIM and the others"
  fi
  export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-hl-copy-api-e2e}"
  api_dir="$(basename "$repo")"
  targets=(hl-sim/bin/main.exe hl-leaderboard/bin/main.exe hl-copy-engine/bin/main.exe
    "$api_dir/bin/main.exe" "$api_dir/tools/dev_wallet.exe")
  if [[ "${SMOKE:-1}" == 1 && -d "$root/hl-copy-web" ]]; then targets+=(hl-copy-web/bin/main.bc.js); fi
  say "building (switch $switch, build dir $DUNE_BUILD_DIR)"
  (cd "$root" && opam exec --switch "$switch" -- dune build --root . "${targets[@]}") \
    >"$log_dir/build.log" 2>&1 || {
    cat "$log_dir/build.log" >&2
    fail "build failed"
  }
  build="$DUNE_BUILD_DIR/default"
  sim_exe="$build/hl-sim/bin/main.exe"
  lb_exe="$build/hl-leaderboard/bin/main.exe"
  engine_exe="$build/hl-copy-engine/bin/main.exe"
  api_exe="$build/$api_dir/bin/main.exe"
  wallet_exe="$build/$api_dir/tools/dev_wallet.exe"
  WEB_JS="${WEB_JS:-$build/hl-copy-web/bin/main.bc.js}"
  WEB_DIR="${WEB_DIR:-$root/hl-copy-web}"
fi

# JSON from stdin: py 'expression over d'
py() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

wait_http() { # name pid url
  for _ in $(seq 1 100); do
    if curl -sf -o /dev/null "$3" 2>/dev/null; then return 0; fi
    kill -0 "$2" 2>/dev/null || fail "$1 exited early"
    sleep 0.2
  done
  fail "$1 did not answer $3"
}

sim="http://127.0.0.1:$sim_port"
lb="http://127.0.0.1:$lb_port"
api="http://127.0.0.1:$api_port"
engine="http://127.0.0.1:$engine_port"
info() { curl -sf "$sim/info" -H 'content-type: application/json' -d "$1"; }

# ---- hl-sim

# Every account starts with $100,000, the leaders' balance, so Equity_ratio copies the
# leader's sizes about one for one: at the default $1,000,000 the follower would need ten
# times the leader's size, which the thin simulated book does not fill in a few minutes.
say "hl-sim on $sim_port (seed $seed, 3 leaders, 40 noise traders, strict signatures)"
"$sim_exe" -port "$sim_port" -seed "$seed" -leaders 3 -noise-traders 40 -strict-signatures \
  -initial-balance 100000 \
  >"$log_dir/sim.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 100); do
  info '{"type":"meta"}' >/dev/null 2>&1 && break
  kill -0 "${pids[${#pids[@]}-1]}" 2>/dev/null || fail "hl-sim exited early"
  sleep 0.2
done
say "letting the market and the leaders trade for ${warmup_s}s"
sleep "$warmup_s"

# ---- hl-leaderboard

say "collecting the leaderboard from the simulator"
# Every account (3 leaders and 40 noise traders) is a candidate; the local simulator
# needs no request budget.
# hl-sim's leaderboard sometimes answers 400 (an ROI overflowing Float.iround) in the
# first minute of a run, so the collection is retried.
collected=0
for attempt in 1 2 3 4; do
  if "$lb_exe" collect -out "$log_dir/leaderboard" -network local -base-url "$sim" \
    -min-account-value 0 -top 50 -lookback-days 1 -weight-per-minute 1000000 \
    >>"$log_dir/leaderboard.log" 2>&1; then
    collected=1
    break
  fi
  say "collect attempt $attempt failed; retrying in 10 s"
  sleep 10
done
((collected)) || fail "hl-leaderboard collect failed"
"$lb_exe" rank -in "$log_dir/leaderboard" -out "$log_dir/leaderboard/leaders.json" \
  -min-trades 1 >>"$log_dir/leaderboard.log" 2>&1 || fail "hl-leaderboard rank failed"
"$lb_exe" serve -port "$lb_port" -dir "$log_dir/leaderboard" >>"$log_dir/leaderboard.log" 2>&1 &
pids+=($!)
wait_http hl-leaderboard "${pids[${#pids[@]}-1]}" "$lb/health"

# ---- PostgreSQL for hl-copy-api

# DATABASE_URL names a server to use (CI's Postgres service); otherwise a throwaway
# cluster is started here (initdb from PG_BINDIR or pg_config --bindir), trusting local
# connections, and stopped on exit. TCP only: macOS caps socket paths at 103 bytes, which a
# LOG_DIR under a deep temporary directory exceeds.
if [[ -z "${DATABASE_URL:-}" ]]; then
  bindir="${PG_BINDIR:-$(pg_config --bindir 2>/dev/null || true)}"
  [[ -x "$bindir/initdb" ]] || fail "no DATABASE_URL and no initdb (set PG_BINDIR or install PostgreSQL)"
  pgdata="$log_dir/pgdata"
  say "throwaway PostgreSQL on $pg_port"
  "$bindir/initdb" -D "$pgdata" -U postgres -A trust >"$log_dir/postgres.log" 2>&1 ||
    fail "initdb failed"
  "$bindir/pg_ctl" -D "$pgdata" -w -l "$log_dir/postgres.log" \
    -o "-p $pg_port -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off" \
    start >/dev/null ||
    fail "postgres did not start"
  stop_pg() { "$bindir/pg_ctl" -D "$pgdata" -m fast stop >/dev/null 2>&1 || true; }
  DATABASE_URL="postgres://postgres@127.0.0.1:$pg_port/postgres?sslmode=disable"
fi
export DATABASE_URL

# ---- hl-copy-api and hl-copy-engine share the key store and its master key

HL_COPY_MASTER_KEY="$(openssl rand -hex 32)"
export HL_COPY_MASTER_KEY
builder="0x$(openssl rand -hex 20)"

say "hl-copy-api on $api_port, hl-copy-engine on $engine_port"
"$api_exe" -port "$api_port" -exchange-url "$sim" -leaderboard-url "$lb" \
  -engine-url "$engine" -state-dir "$state" -config-dir "$configs" \
  -public-url "$api" -allow-origin '*' -builder "$builder" -builder-fee 10 \
  >"$log_dir/api.log" 2>&1 &
pids+=($!)
wait_http hl-copy-api "${pids[${#pids[@]}-1]}" "$api/healthz"

"$engine_exe" run -base-url "$sim" -configs-dir "$configs" -journal-dir "$journal" \
  -state-dir "$state" -port "$engine_port" -resync-s "$resync_s" \
  >"$log_dir/engine.log" 2>&1 &
engine_pid=$!
pids+=("$engine_pid")
wait_http hl-copy-engine "$engine_pid" "$engine/healthz"

# ---- The user's flow

HL_COPY_WALLET_KEY="0x$(openssl rand -hex 32)"
export HL_COPY_WALLET_KEY
wallet="$("$wallet_exe" address)"
say "wallet $wallet (throwaway)"

post() { # path json [token]
  curl -sf -X POST "$api$1" -H 'content-type: application/json' \
    ${3:+-H "authorization: Bearer $3"} -d "$2"
}
get() { curl -sf "$api$1" -H "authorization: Bearer $2"; }

challenge="$(post /auth/challenge "{\"address\":\"$wallet\"}")" || fail "/auth/challenge"
# The message goes to the signer byte for byte (no trailing newline).
signature="$(printf '%s' "$challenge" |
  python3 -I -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["message"])' |
  "$wallet_exe" personal-sign)"
nonce="$(printf '%s' "$challenge" | py 'd["nonce"]')"
token="$(post /auth/verify "{\"address\":\"$wallet\",\"nonce\":\"$nonce\",\"signature\":\"$signature\"}" |
  py 'd["token"]')" || fail "/auth/verify"
say "logged in"

offer="$(post /agent/new '{}' "$token")" || fail "/agent/new"
agent_sig="$(printf '%s' "$offer" | py 'json.dumps(d["typed_data"]["approve_agent"])' |
  "$wallet_exe" sign-typed-data)"
approval="$(printf '%s' "$offer" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({"approve_agent": d["approve_agent"], "signature": sys.argv[1]}))' "$agent_sig")"
status="$(post /agent/approved "$approval" "$token")" || fail "/agent/approved"
[[ "$(printf '%s' "$status" | py 'd["approved"]')" == True ]] || fail "agent not approved: $status"
fee_sig="$(printf '%s' "$offer" | py 'json.dumps(d["typed_data"]["approve_builder_fee"])' |
  "$wallet_exe" sign-typed-data)"
fee="$(printf '%s' "$offer" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({"approve_builder_fee": d["approve_builder_fee"], "signature": sys.argv[1]}))' "$fee_sig")"
status="$(post /builder-fee "$fee" "$token")" || fail "/builder-fee"
[[ "$(printf '%s' "$status" | py 'd.get("builder_fee")')" == "0.01%" ]] ||
  fail "builder fee not recorded: $status"
say "agent approved, builder fee 0.01% approved"

leaders="$(curl -sf "$api/leaders")" || fail "/leaders"
printf '%s' "$leaders" | python3 -I -c '
import json, sys
leaders = json.load(sys.stdin)["leaders"]
if not any(l["address"] == sys.argv[1] for l in leaders):
    sys.exit("leader %s is not on the leaderboard (%d leaders)" % (sys.argv[1], len(leaders)))
print("e2e-stack: %d leaders ranked; following %s" % (len(leaders), sys.argv[1]), file=sys.stderr)
' "$leader" || fail "leader missing"

# The websocket listener records every push from now on.
node_ok=0
if command -v node >/dev/null && node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)'; then
  node_ok=1
  node -e '
const fs = require("fs");
const ws = new WebSocket(process.argv[1]);
ws.onmessage = (m) => fs.appendFileSync(process.argv[2], m.data + "\n");
ws.onerror = (e) => { console.error("ws error", e.message || e); process.exit(1); };
ws.onclose = () => process.exit(0);
' "ws://127.0.0.1:$api_port/ws?token=$token" "$log_dir/ws.ndjson" 2>"$log_dir/ws.log" &
  pids+=($!)
else
  say "node 22 or newer (global WebSocket) not found: skipping the /ws checks"
fi
sleep 1

coin=BTC # the simulator's leaders 0 to 2 trade BTC
max_leverage=5
max_notional=2000000
follow_body="{\"leader\":\"$leader\",\"scale\":{\"kind\":\"equity_ratio\"},
  \"caps\":{\"max_leverage\":$max_leverage,\"max_notional_per_symbol\":$max_notional,
            \"max_daily_loss\":100000,\"allowlist\":[\"$coin\"],\"min_order_notional\":10}}"
follow="$(post /follows "$follow_body" "$token")" || fail "POST /follows"
follow_id="$(printf '%s' "$follow" | py 'd["id"]')"
config="$configs/$wallet-$leader.sexp"
[[ -f "$config" ]] || fail "no follower config at $config"
say "follow $follow_id running; sampling every 10 s for ${follow_s}s"

position() { # address -> size of $coin (0 when flat)
  info "{\"type\":\"clearinghouseState\",\"user\":\"$1\"}" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
print(next((p["position"]["szi"] for p in s["assetPositions"] if p["position"]["coin"] == sys.argv[1]), "0"))
' "$coin"
}

metric() { # name [quantile]
  curl -sf "$engine/metrics" | python3 -I -c '
import re, sys
name, q = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
total = None
for line in sys.stdin:
    if line.startswith("#"): continue
    m = re.match(r"([a-z_]+)(\{[^}]*\})?\s+(\S+)", line)
    if not m or m.group(1) != name: continue
    labels = m.group(2) or ""
    if q is not None and ("quantile=\"%s\"" % q) not in labels: continue
    if q is None and "quantile=" in labels: continue
    total = (total or 0) + float(m.group(3))
print("0" if total is None else ("%g" % total))
' "$@"
}

elapsed=0
while ((elapsed < follow_s)); do
  sleep 10
  elapsed=$((elapsed + 10))
  kill -0 "$engine_pid" 2>/dev/null || fail "the engine exited"
  printf '  %3ss  leader %s=%-10s follower %s=%-10s orders %s fills %s\n' "$elapsed" \
    "$coin" "$(position "$leader")" "$coin" "$(position "$wallet")" \
    "$(metric hl_copy_orders_total)" "$(metric hl_copy_fills_total)" >&2
done

# ---- Positions in /me track the leader

# Target: the leader's size times follower equity over leader equity (Equity_ratio), with
# the equities and the leader's position as the engine sees them in /status; the caps
# above do not bind at these sizes. Tolerance: one lot, plus the $10 minimum order below
# which the engine does not trade.
meta="$(info '{"type":"meta"}')"
lot="$(printf '%s' "$meta" | python3 -I -c '
import json, sys
u = next(a for a in json.load(sys.stdin)["universe"] if a["name"] == sys.argv[1])
print(10 ** -u["szDecimals"])' "$coin")"
track() {
  local me status mids
  me="$(get /me "$token")" || return 2
  status="$(curl -sf "$engine/status")" || return 2
  mids="$(info '{"type":"allMids"}')" || return 2
  python3 -I - "$me" "$status" "$mids" "$wallet" "$leader" "$coin" "$lot" "$(position "$wallet")" <<'PY'
import json, sys
me, status, mids = (json.loads(a) for a in sys.argv[1:4])
wallet, leader, coin, lot, actual = sys.argv[4], sys.argv[5], sys.argv[6], float(sys.argv[7]), float(sys.argv[8])
follow = next(f for f in me["follows"] if f["leader"] == leader)
mine = next((p["size"] for p in follow["positions"] if p["coin"] == coin), 0.0)
f = next(f for f in status["followers"] if f["follower"] == wallet and f["leader"] == leader)
def size(ps):
    if isinstance(ps, dict): ps = [{"coin": k, "size": v} for k, v in ps.items()]
    for p in ps or []:
        if p.get("coin") == coin: return float(p.get("size", p.get("szi", 0)))
    return 0.0
le, fe = float(f["leader_equity"]), float(f["follower_equity"])
target_raw = size(f["leader_positions"]) * fe / le if le > 0 else 0.0
target = int(abs(target_raw) / lot) * lot * (1 if target_raw >= 0 else -1)
mark = float(mids[coin])
tolerance = lot + 10.0 / mark
ok = abs(mine - target) <= tolerance + 1e-12 and abs(mine - actual) <= lot / 2
print(json.dumps({"ok": ok, "me": mine, "exchange": actual, "target": round(target, 8),
                  "leader": size(f["leader_positions"]), "tolerance": round(tolerance, 8),
                  "pending": f.get("pending")}))
sys.exit(0 if ok and mine != 0 else 1)
PY
}
tracked=""
deadline=$((SECONDS + track_wait_s))
while :; do
  if out="$(track)"; then
    tracked="$out"
    break
  fi
  ((SECONDS < deadline)) || fail "positions in /me do not track the leader: $out"
  sleep 2
done
say "tracking: $tracked"

# ---- Pause: orders cancelled, no new ones

curl -sf -X PATCH "$api/follows/$follow_id" -H "authorization: Bearer $token" \
  -H 'content-type: application/json' -d '{"state":"paused"}' >/dev/null || fail "pause"
grep -q '(paused true)' "$config" || fail "the follower config is not paused"
sleep $((resync_s + 3))
orders_paused="$(metric hl_copy_orders_total)"
engine_state="$(curl -sf "$engine/status" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
print(next(f["state"] for f in s["followers"] if f["follower"] == sys.argv[1]))' "$wallet")"
[[ "$engine_state" == paused ]] || fail "the engine says $engine_state after pause"
open_orders="$(info "{\"type\":\"openOrders\",\"user\":\"$wallet\"}" | py 'len(d)')"
((open_orders == 0)) || fail "$open_orders open orders after pause"
sleep $((resync_s * 2))
[[ "$(metric hl_copy_orders_total)" == "$orders_paused" ]] || fail "orders sent while paused"
say "paused: engine state paused, no open orders, no new orders over $((resync_s * 2))s"

# ---- Summary numbers, read before the stop removes the follower's metrics

me="$(get /me "$token")"
follower_metric() { # expression over m, the follower's metrics in the engine's /status
  curl -sf "$engine/status" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
m = next(f for f in s["followers"] if f["follower"] == sys.argv[1])["metrics"]
v = eval(sys.argv[2])
print("-" if v is None else "%.2f" % v)' "$wallet" "$1"
}
summary_metrics=(
  "orders:$(metric hl_copy_orders_total)"
  "fills:$(metric hl_copy_fills_total)"
  "rejects:$(metric hl_copy_rejects_total)"
  "resyncs:$(metric hl_copy_resyncs_total)"
  "lag p50 (ms):$(follower_metric 'm["lag_ms"]["p50"]')"
  "lag max (ms):$(follower_metric 'm["lag_ms"]["max"]')"
  "slippage p50 (bps):$(metric hl_copy_slippage_bps 0.5)"
  "slippage p90 (bps):$(metric hl_copy_slippage_bps 0.9)"
  "follow pnl (USD):$(printf '%s' "$me" | py '"%.2f" % d["follows"][0]["pnl"]')"
  "account value (USD):$(printf '%s' "$me" | py '"%.2f" % d["account_value"]')"
)
curl -sf "$engine/metrics" >"$log_dir/metrics.txt" || true
curl -sf "$engine/status" >"$log_dir/status.json" || true

# ---- Stop: config removed

curl -sf -X DELETE "$api/follows/$follow_id" -H "authorization: Bearer $token" >/dev/null ||
  fail "stop"
[[ ! -f "$config" ]] || fail "the follower config is still there after stop"
[[ "$(get "/follows/$follow_id" "$token" | py 'd["state"]')" == stopped ]] ||
  fail "the follow is not stopped"
for _ in $(seq 1 20); do
  listed="$(curl -sf "$engine/status" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
print(sum(1 for f in s["followers"] if f["follower"] == sys.argv[1] and f["state"] != "stopped"))' "$wallet")"
  ((listed == 0)) && break
  sleep 0.5
done
((listed == 0)) || fail "the engine still runs the follow after stop"
say "stopped: config removed, the engine dropped the follower"

# ---- /ws

if ((node_ok)); then
  sleep 1
  ws_counts="$(python3 -I -c '
import collections, json, sys
c = collections.Counter(json.loads(l)["type"] for l in open(sys.argv[1]) if l.strip())
print(" ".join("%s=%d" % kv for kv in sorted(c.items())))' "$log_dir/ws.ndjson" 2>/dev/null || true)"
  [[ "$ws_counts" == *follow=* ]] || fail "/ws pushed no follow event ($ws_counts)"
  [[ "$ws_counts" == *fill=* ]] || fail "/ws pushed no fill event ($ws_counts)"
  summary_metrics+=("ws pushes:$ws_counts")
  say "/ws: $ws_counts"
fi

# ---- hl-copy-web's live smoke test against this API

if [[ "${SMOKE:-1}" == 1 && $node_ok == 1 && -f "${WEB_JS:-}" && -f "${WEB_DIR:-}/smoke/live.js" ]]; then
  say "hl-copy-web smoke/live.js against $api"
  HL_COPY_WALLET_KEY="0x$(openssl rand -hex 32)" DEV_WALLET="$wallet_exe" \
    node "$WEB_DIR/smoke/live.js" "$WEB_JS" "$WEB_DIR" "$api" >"$log_dir/smoke.log" 2>&1 || {
    cat "$log_dir/smoke.log" >&2
    fail "the web smoke test failed against the real API"
  }
  summary_metrics+=("web smoke:$(tail -n 1 "$log_dir/smoke.log")")
elif [[ "${SMOKE:-1}" == 1 ]]; then
  say "skipping the web smoke test (needs node 22, WEB_JS and WEB_DIR)"
fi

# ---- Journal replay

kill "$engine_pid" 2>/dev/null || true
wait "$engine_pid" 2>/dev/null || true
"$engine_exe" replay "$journal/$wallet-$leader" >"$log_dir/replay.txt" 2>&1 ||
  {
    cat "$log_dir/replay.txt" >&2
    fail "the journal does not replay"
  }
grep -q '(identical true)' "$log_dir/replay.txt" || fail "the journal replays differently"
summary_metrics+=("journal:$(tail -n 1 "$log_dir/replay.txt")")

echo
printf '%-22s %s\n' "check" "result"
printf '%-22s %s\n' "tracking ($coin)" "$tracked"
for m in "${summary_metrics[@]}"; do
  printf '%-22s %s\n' "${m%%:*}" "${m#*:}"
done
echo
say "ok; logs in $log_dir"
