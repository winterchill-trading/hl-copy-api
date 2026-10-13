open! Core
open! Async
open Hl_copy_api
module Address = Hl_protocol.Address

let leader = Address.of_string "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf"
let followers a = if Address.equal a leader then 3 else 0
let print_json yojson_of x = print_endline (Yojson.Safe.pretty_to_string (yojson_of x))

let%expect_test "ranking entries become Api_types leaders" =
  Yojson.Safe.from_file "fixtures/leaders.json"
  |> Leaders.leaders_of_json ~followers
  |> Or_error.ok_exn
  |> print_json Api_types.Leaders_response.yojson_of_t;
  [%expect
    {|
    {
      "as_of": 1791871200000,
      "leaders": [
        {
          "address": "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf",
          "display_name": "alpha",
          "rank": 1,
          "score": 42.31,
          "breakdown": {
            "pnl": 90.0,
            "roi": 0.62,
            "max_drawdown": 0.12,
            "win_rate": 0.5,
            "trade_count": 6,
            "avg_hold_secs": 59.99976,
            "consistency": 0.75
          },
          "account_value": 125000.5,
          "window_pnl": {
            "day": 120.5,
            "week": -300.0,
            "month": 4100.25,
            "all_time": 90000.0
          },
          "followers": 3
        },
        {
          "address": "0x0000000000000000000000000000000000000abc",
          "rank": 2,
          "score": 0.0,
          "breakdown": {
            "pnl": -3.0,
            "roi": -0.001,
            "max_drawdown": 0.0,
            "win_rate": 0.0,
            "trade_count": 0,
            "avg_hold_secs": 0.0,
            "consistency": 0.0
          },
          "account_value": 5000.0,
          "window_pnl": {
            "day": 0.0,
            "week": 0.0,
            "month": 10.0,
            "all_time": 0.0
          },
          "followers": 0
        }
      ]
    }
    |}];
  return ()
;;

let%expect_test "leader detail" =
  Yojson.Safe.from_file "fixtures/leader.json"
  |> Leaders.leader_detail_of_json ~followers
  |> Or_error.ok_exn
  |> print_json Api_types.Leader_detail.yojson_of_t;
  [%expect
    {|
    {
      "leader": {
        "address": "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf",
        "display_name": "alpha",
        "rank": 1,
        "score": 42.31,
        "breakdown": {
          "pnl": 90.0,
          "roi": 0.62,
          "max_drawdown": 0.12,
          "win_rate": 0.5,
          "trade_count": 6,
          "avg_hold_secs": 1800.0,
          "consistency": 0.75
        },
        "account_value": 125000.5,
        "window_pnl": {
          "day": 0.0,
          "week": 0.0,
          "month": 4100.25,
          "all_time": 0.0
        },
        "followers": 3
      },
      "equity_curve": [
        { "time": 1791864660000, "equity": 124000.0 },
        { "time": 1791868260000, "equity": 125000.5 }
      ],
      "fills": [
        {
          "time": 1791868260000,
          "coin": "BTC",
          "side": "sell",
          "px": 100000.0,
          "sz": 1.0,
          "closed_pnl": -10.0,
          "fee": 1.0,
          "dir": "Close Long"
        },
        {
          "time": 1791868200000,
          "coin": "BTC",
          "side": "buy",
          "px": 100000.0,
          "sz": 1.0,
          "closed_pnl": 0.0,
          "fee": 1.0,
          "dir": "Open Long"
        }
      ],
      "positions": [
        {
          "coin": "BTC",
          "size": -0.5,
          "entry_px": 83484.39999999999,
          "unrealized_pnl": 12.5,
          "leverage": 20.0
        }
      ]
    }
    |}];
  return ()
;;

let%expect_test "proxied from hl-leaderboard serve" =
  Log.Global.set_output [];
  Sim.with_dir (fun dir ->
    let ranking = dir ^/ "leaders.json" in
    let%bind () =
      Writer.save ranking ~contents:(In_channel.read_all "fixtures/leaders.json")
    in
    let%bind server = Hl_leaderboard.Server.start ~dir ~leaders:ranking ~port:0 in
    let t =
      Leaders.create
        ~base_url:
          (Uri.of_string
             (sprintf "http://127.0.0.1:%d" (Hl_leaderboard.Server.port server)))
        ()
    in
    let%bind r = Leaders.leaders t ~followers in
    print_s
      [%sexp
        (Or_error.map r ~f:(fun r ->
           List.map r.leaders ~f:(fun l -> l.rank, Api_types.Address.short l.address))
         : (int * string) list Or_error.t)];
    [%expect {| (Ok ((1 0x87f9...e2cf) (2 0x0000...0abc))) |}];
    (* Nothing was collected for the leader, so the leaderboard answers 404. *)
    let%bind r = Leaders.leader t ~followers leader in
    print_s [%sexp (Or_error.map r ~f:Option.is_some : bool Or_error.t)];
    [%expect {| (Ok false) |}];
    let%bind () = Hl_leaderboard.Server.close server in
    let%bind r =
      Leaders.leaders
        (Leaders.create ~base_url:(Uri.of_string "http://127.0.0.1:1") ())
        ~followers
    in
    print_s [%sexp (Result.is_error r : bool)];
    [%expect {| true |}];
    return ())
;;
