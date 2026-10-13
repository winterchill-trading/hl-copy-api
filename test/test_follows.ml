open! Core
open! Async
open Hl_copy_api
module Address = Hl_protocol.Address

let follower = Address.of_string "0x1111111111111111111111111111111111111111"
let leader = Address.of_string "0x2222222222222222222222222222222222222222"
let other_user = Address.of_string "0x3333333333333333333333333333333333333333"

let caps : Api_types.Caps.t =
  { max_leverage = 5.
  ; max_notional_per_symbol = 0.
  ; max_daily_loss = 200.
  ; allowlist = [ "BTC"; "ETH" ]
  ; min_order_notional = 10.
  }
;;

let ls dir =
  match Sys_unix.readdir dir with
  | exception _ -> print_s [%sexp ([] : string list)]
  | files ->
    print_s
      [%sexp (Array.to_list files |> List.sort ~compare:String.compare : string list)]
;;

let cat path = print_string (In_channel.read_all path)

let%expect_test "start, pause, resume, stop, start again" =
  Sim.with_dir (fun dir ->
    let config_dir = dir ^/ "configs" in
    let t = Follows.create ~config_dir ~state_dir:(dir ^/ "follows") in
    let r =
      Follows.start t ~follower ~leader ~scale:(Multiplier 0.5) ~caps ~now_ms:1
      |> Or_error.ok_exn
    in
    print_endline r.id;
    ls config_dir;
    cat (config_dir ^/ r.id ^ ".sexp");
    [%expect
      {|
      0x1111111111111111111111111111111111111111-0x2222222222222222222222222222222222222222
      (0x1111111111111111111111111111111111111111-0x2222222222222222222222222222222222222222.sexp)
      ((follower 0x1111111111111111111111111111111111111111)
       (leader 0x2222222222222222222222222222222222222222) (mode (Multiplier 0.5))
       (caps
        ((max_leverage (5)) (max_notional_per_symbol ()) (max_daily_loss (200))
         (allowlist ((BTC ETH))) (min_order_notional 10)))
       (slippage_bps 20) (paused false))
      |}];
    (* The engine's parser accepts what was written. *)
    print_s
      [%sexp
        (Hl_copy_core.Follower_config.of_file_contents
           (In_channel.read_all (config_dir ^/ r.id ^ ".sexp"))
         |> Result.is_ok
         : bool)];
    [%expect {| true |}];
    print_s
      [%sexp
        (Follows.start t ~follower ~leader ~scale:Equity_ratio ~caps ~now_ms:2
         : Follows.Record.t Or_error.t)];
    [%expect
      {|
      (Error
       ("already following this leader"
        (id
         0x1111111111111111111111111111111111111111-0x2222222222222222222222222222222222222222)))
      |}];
    let state ?scale s =
      let r =
        Follows.update t ~follower r.id ?scale ~state:s ~now_ms:3 () |> Or_error.ok_exn
      in
      print_s [%sexp (r.state : Api_types.Follow_state.t)]
    in
    state Paused;
    print_s
      [%sexp
        (String.is_substring
           (In_channel.read_all (config_dir ^/ r.id ^ ".sexp"))
           ~substring:"(paused true)"
         : bool)];
    state Running;
    state Stopped;
    ls config_dir;
    [%expect {|
      Paused
      true
      Running
      Stopped
      ()
      |}];
    print_s
      [%sexp
        (Follows.update t ~follower r.id ~state:Running ~now_ms:4 () |> Result.is_error
         : bool)];
    [%expect {| true |}];
    let again =
      Follows.start t ~follower ~leader ~scale:Equity_ratio ~caps ~now_ms:5
      |> Or_error.ok_exn
    in
    print_s
      [%sexp
        (again.state : Api_types.Follow_state.t)
        , (again.created_ms : int)
        , (again.scale : Api_types.Scale_mode.t)];
    ls config_dir;
    [%expect
      {|
      (Running 1 Equity_ratio)
      (0x1111111111111111111111111111111111111111-0x2222222222222222222222222222222222222222.sexp)
      |}];
    return ())
;;

let%expect_test "follows are private to their user, and ids are checked" =
  Sim.with_dir (fun dir ->
    let t = Follows.create ~config_dir:(dir ^/ "c") ~state_dir:(dir ^/ "s") in
    let r =
      Follows.start t ~follower ~leader ~scale:Equity_ratio ~caps ~now_ms:1
      |> Or_error.ok_exn
    in
    print_s
      [%sexp
        (Option.is_some (Follows.find t ~follower r.id) : bool)
        , (Option.is_some (Follows.find t ~follower:other_user r.id) : bool)
        , (List.length (Follows.list t ~follower:other_user) : int)
        , (Option.is_some (Follows.find t ~follower "../../etc/passwd") : bool)];
    [%expect {| (true false 0 false) |}];
    return ())
;;

let%expect_test "invalid settings write nothing" =
  Sim.with_dir (fun dir ->
    let config_dir = dir ^/ "c" in
    let t = Follows.create ~config_dir ~state_dir:(dir ^/ "s") in
    let show r =
      print_s
        [%sexp
          (Result.map r ~f:(fun (r : Follows.Record.t) -> r.id) |> Result.is_ok : bool)]
    in
    show (Follows.start t ~follower ~leader:follower ~scale:Equity_ratio ~caps ~now_ms:1);
    show (Follows.start t ~follower ~leader ~scale:(Multiplier Float.nan) ~caps ~now_ms:1);
    show
      (Follows.start
         t
         ~follower
         ~leader
         ~scale:(Fixed_notional Float.infinity)
         ~caps
         ~now_ms:1);
    show
      (Follows.start
         t
         ~follower
         ~leader
         ~scale:Equity_ratio
         ~caps:{ caps with min_order_notional = -1. }
         ~now_ms:1);
    ls config_dir;
    [%expect {|
      false
      false
      false
      false
      ()
      |}];
    return ())
;;
