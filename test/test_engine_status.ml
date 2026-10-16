open! Core
open! Async
open Hl_copy_api

let%expect_test "lenient decoding" =
  {|{"followers":[
      {"follower":"0x1111111111111111111111111111111111111111",
       "leader":"0x2222222222222222222222222222222222222222",
       "state":"running","pnl":"12.5",
       "positions":[{"coin":"BTC","size":0.01,"entry_px":100000,"unrealized_pnl":1.2,"leverage":3},
                    {"size":1}]},
      {"follower":"0x1111111111111111111111111111111111111111","leader":"nope"},
      {"follower":"0x1111111111111111111111111111111111111111",
       "leader":"0x3333333333333333333333333333333333333333","last_error":"margin"}
    ],"other":1}|}
  |> Yojson.Safe.from_string
  |> Engine_status.of_json
  |> [%sexp_of: Engine_status.t]
  |> print_s;
  [%expect
    {|
    (((follower 0x1111111111111111111111111111111111111111)
      (leader 0x2222222222222222222222222222222222222222) (state (running))
      (pnl 12.5)
      (positions
       (((coin BTC) (size 0.01) (entry_px 100000) (unrealized_pnl 1.2)
         (leverage 3))))
      (last_error ()) (execution ()))
     ((follower 0x1111111111111111111111111111111111111111)
      (leader 0x3333333333333333333333333333333333333333) (state ()) (pnl 0)
      (positions ()) (last_error (margin)) (execution ())))
    |}];
  print_s [%sexp (Engine_status.of_json (`List []) : Engine_status.t)];
  [%expect {| () |}];
  return ()
;;

let%expect_test "an unreachable engine is empty" =
  let%bind t = Engine_status.fetch (Some (Uri.of_string "http://127.0.0.1:1")) in
  print_s [%sexp (t : Engine_status.t)];
  let%bind t = Engine_status.fetch None in
  print_s [%sexp (t : Engine_status.t)];
  [%expect {|
    ()
    ()
    |}];
  return ()
;;

let%expect_test "the execution block of a follower's status" =
  {|{"followers":[
      {"follower":"0x1111111111111111111111111111111111111111",
       "leader":"0x2222222222222222222222222222222222222222",
       "execution":{"algo":"twap",
         "active":[{"cloid":"0x1","coin":"BTC"}],
         "recent":[
           {"time":"2026-10-16T01:02:03.250000000Z","algo":"twap","outcome":"filled",
            "side":"buy","target":0.02,"filled":0.02,"avg_px":100010,"arrival_px":100000,
            "children":6,"maker_filled":0,"fees":0.9,"arrival_slippage_bps":1,
            "shortfall":0.2,"shortfall_bps":1.45},
           {"time":"2026-10-16T01:03:00Z","algo":"twap","outcome":"partial","side":"sell",
            "target":0.01,"filled":0.005,"avg_px":99990,"arrival_px":100000,"children":6,
            "fees":0.2,"arrival_slippage_bps":1,"shortfall":0.1,"shortfall_bps":2.5}],
         "totals":{"parents":2,"filled_parents":1,"target_notional":3000,
           "filled_notional":2500,"fees":1.1,"shortfall":0.3,"shortfall_bps":1.2,
           "slippage_bps":1,"fill_rate":0.83}}}]}|}
  |> Yojson.Safe.from_string
  |> Engine_status.of_json
  |> List.iter ~f:(fun (s : Engine_status.Follow_status.t) ->
    print_s [%sexp (s.execution : Api_types.Execution.t option)]);
  [%expect
    {|
    (((algo twap) (parents 2) (filled_parents 1) (fill_rate 0.83)
      (shortfall_bps 1.2) (slippage_bps 1) (fees 1.1) (active 1)
      (recent
       (((time (1792112580000)) (algo twap) (outcome partial) (side Sell)
         (target 0.01) (filled 0.005) (avg_px 99990) (arrival_px 100000)
         (children 6) (fees 0.2) (arrival_slippage_bps 1) (shortfall_bps 2.5))
        ((time (1792112523250)) (algo twap) (outcome filled) (side Buy)
         (target 0.02) (filled 0.02) (avg_px 100010) (arrival_px 100000)
         (children 6) (fees 0.9) (arrival_slippage_bps 1) (shortfall_bps 1.45))))))
    |}];
  return ()
;;
