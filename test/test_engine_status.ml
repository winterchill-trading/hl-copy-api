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
      (last_error ()))
     ((follower 0x1111111111111111111111111111111111111111)
      (leader 0x3333333333333333333333333333333333333333) (state ()) (pnl 0)
      (positions ()) (last_error (margin))))
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
