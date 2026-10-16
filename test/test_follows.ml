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
let memory () = Store_memory.store (Store_memory.create ())

let%expect_test "start, pause, resume, stop, start again" =
  Sim.with_dir (fun dir ->
    let config_dir = dir ^/ "configs" in
    let t = Follows.create ~store:(memory ()) ~config_dir in
    let%bind r =
      Follows.start t ~follower ~leader ~scale:(Multiplier 0.5) ~caps ~now_ms:1 ()
      >>| Or_error.ok_exn
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
    let%bind again =
      Follows.start t ~follower ~leader ~scale:Equity_ratio ~caps ~now_ms:2 ()
    in
    print_s [%sexp (again : Follows.Record.t Or_error.t)];
    [%expect
      {|
      (Error
       ("already following this leader"
        (id
         0x1111111111111111111111111111111111111111-0x2222222222222222222222222222222222222222)))
      |}];
    let state ?scale s =
      let%map r =
        Follows.update t ~follower r.id ?scale ~state:s ~now_ms:3 () >>| Or_error.ok_exn
      in
      print_s [%sexp (r.state : Api_types.Follow_state.t)]
    in
    let%bind () = state Paused in
    print_s
      [%sexp
        (String.is_substring
           (In_channel.read_all (config_dir ^/ r.id ^ ".sexp"))
           ~substring:"(paused true)"
         : bool)];
    let%bind () = state Running in
    let%bind () = state Stopped in
    ls config_dir;
    [%expect {|
      Paused
      true
      Running
      Stopped
      ()
      |}];
    let%bind restarted = Follows.update t ~follower r.id ~state:Running ~now_ms:4 () in
    print_s [%sexp (Result.is_error restarted : bool)];
    [%expect {| true |}];
    let%bind again =
      Follows.start t ~follower ~leader ~scale:Equity_ratio ~caps ~now_ms:5 ()
      >>| Or_error.ok_exn
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
    let t = Follows.create ~store:(memory ()) ~config_dir:(dir ^/ "c") in
    let%bind r =
      Follows.start t ~follower ~leader ~scale:Equity_ratio ~caps ~now_ms:1 ()
      >>| Or_error.ok_exn
    in
    let found ~follower id =
      Follows.find t ~follower id >>| Or_error.ok_exn >>| Option.is_some
    in
    let%bind own = found ~follower r.id in
    let%bind other = found ~follower:other_user r.id in
    let%bind others = Follows.list t ~follower:other_user >>| Or_error.ok_exn in
    let%bind path = found ~follower "../../etc/passwd" in
    print_s
      [%sexp (own : bool), (other : bool), (List.length others : int), (path : bool)];
    [%expect {| (true false 0 false) |}];
    return ())
;;

let%expect_test "invalid settings write nothing" =
  Sim.with_dir (fun dir ->
    let config_dir = dir ^/ "c" in
    let t = Follows.create ~store:(memory ()) ~config_dir in
    let show r =
      let%map r in
      print_s
        [%sexp
          (Result.map r ~f:(fun (r : Follows.Record.t) -> r.id) |> Result.is_ok : bool)]
    in
    let%bind () =
      show
        (Follows.start
           t
           ~follower
           ~leader:follower
           ~scale:Equity_ratio
           ~caps
           ~now_ms:1
           ())
    in
    let%bind () =
      show
        (Follows.start
           t
           ~follower
           ~leader
           ~scale:(Multiplier Float.nan)
           ~caps
           ~now_ms:1
           ())
    in
    let%bind () =
      show
        (Follows.start
           t
           ~follower
           ~leader
           ~scale:(Fixed_notional Float.infinity)
           ~caps
           ~now_ms:1
           ())
    in
    let%bind () =
      show
        (Follows.start
           t
           ~follower
           ~leader
           ~scale:Equity_ratio
           ~caps:{ caps with min_order_notional = -1. }
           ~now_ms:1
           ())
    in
    ls config_dir;
    let%bind all = Follows.all t >>| Or_error.ok_exn in
    print_s [%sexp (List.length all : int)];
    [%expect {|
      false
      false
      false
      false
      ()
      0
      |}];
    return ())
;;

let%expect_test "sync_configs makes the config directory match the store" =
  (* Skipped and removed files are logged; the log is not part of the output. *)
  Log.Global.set_output [];
  Sim.with_dir (fun dir ->
    let config_dir = dir ^/ "c" in
    let store = memory () in
    let t = Follows.create ~store ~config_dir in
    let start leader =
      Follows.start t ~follower ~leader ~scale:Equity_ratio ~caps ~now_ms:1 ()
      >>| Or_error.ok_exn
    in
    let%bind running = start leader in
    let%bind stopped = start other_user in
    let%bind (_ : Follows.Record.t) =
      Follows.update t ~follower stopped.id ~state:Stopped ~now_ms:2 ()
      >>| Or_error.ok_exn
    in
    (* The running follow's file is lost, a stopped follow's file and a config for a
       follow the store never had appear; files of any other shape are left alone. *)
    Core_unix.unlink (config_dir ^/ running.id ^ ".sexp");
    let stray = Follows.id ~follower:other_user ~leader in
    List.iter
      [ stopped.id ^ ".sexp"; stray ^ ".sexp"; "notes.txt" ]
      ~f:(fun name -> Out_channel.write_all (config_dir ^/ name) ~data:"()");
    let%bind () = Follows.sync_configs t >>| Or_error.ok_exn in
    ls config_dir;
    [%expect
      {|
      (0x1111111111111111111111111111111111111111-0x2222222222222222222222222222222222222222.sexp
       notes.txt)
      |}];
    return ())
;;

let%expect_test "records of the file-based version are imported once" =
  (* Skipped and removed files are logged; the log is not part of the output. *)
  Log.Global.set_output [];
  Sim.with_dir (fun dir ->
    let old_dir = dir ^/ "state" ^/ "follows" in
    Core_unix.mkdir_p old_dir;
    let record : Follows.Record.t =
      { id = Follows.id ~follower ~leader
      ; follower
      ; leader
      ; scale = Multiplier 2.
      ; caps
      ; state = Paused
      ; created_ms = 7
      ; updated_ms = 8
      ; algo = None
      }
    in
    Out_channel.write_all
      (old_dir ^/ record.id ^ ".sexp")
      ~data:(Sexp.to_string_hum (Follows.Record.sexp_of_t record));
    Out_channel.write_all (old_dir ^/ "broken.sexp") ~data:"(";
    Out_channel.write_all (old_dir ^/ ".tmp.sexp") ~data:"(";
    let t = Follows.create ~store:(memory ()) ~config_dir:(dir ^/ "c") in
    let%bind first = Follows.import_records t ~dir:old_dir >>| Or_error.ok_exn in
    let%bind second = Follows.import_records t ~dir:old_dir >>| Or_error.ok_exn in
    let%bind all = Follows.all t >>| Or_error.ok_exn in
    print_s
      [%message
        (first : int)
          (second : int)
          ~same:(List.equal Follows.Record.equal all [ record ] : bool)];
    [%expect {| ((first 1) (second 0) (same true)) |}];
    return ())
;;
