open! Core
open Hl_copy_api

let%expect_test "parse: execution-algos' forms, canonical, immediate is none" =
  List.iter
    [ "immediate"
    ; "twap"
    ; "twap:90s:3"
    ; " adaptive:20s "
    ; "passive:30s"
    ; "iceberg:0.25:30s"
    ; "pov:0.1"
    ; "twap:0s"
    ; "pov:2"
    ; "market"
    ]
    ~f:(fun s ->
      print_s [%message s ~_:(Exec_algo_spec.parse s : string option Or_error.t)]);
  [%expect
    {|
    (immediate (Ok ()))
    (twap (Ok (twap:1m:6)))
    (twap:90s:3 (Ok (twap:90s:3)))
    (" adaptive:20s " (Ok (adaptive:20s)))
    (passive:30s (Ok (passive:30s)))
    (iceberg:0.25:30s (Ok (iceberg:0.25:30s)))
    (pov:0.1 (Ok (pov:0.1:5m)))
    (twap:0s
     (Error
      ("invalid execution algorithm"
       ("invalid algo" (errors ("duration must be positive"))))))
    (pov:2
     (Error
      ("invalid execution algorithm"
       ("invalid algo" (errors ("participation must be in (0, 1]"))))))
    (market (Error ("invalid execution algorithm" ("unknown algo" market))))
    |}]
;;

(* hl-copy-core's copy of the type must read execution-algos' sexp for every constructor,
   or a follow file would not load in the engine. *)
let%expect_test "every algorithm reaches the engine's type unchanged" =
  List.iter
    Execution_algos.Algo.[ Immediate; twap; vwap; pov; passive; iceberg; adaptive ]
    ~f:(fun a ->
      let spec =
        match Exec_algo_spec.parse (Execution_algos.Algo.to_string a) with
        | Ok s -> s
        | Error e -> Error.raise e
      in
      let engine = Exec_algo_spec.to_exec_algo spec |> Or_error.ok_exn in
      print_s
        [%message
          (Execution_algos.Algo.name a)
            ~same:
              (Sexp.equal
                 (Execution_algos.Algo.sexp_of_t a)
                 (Hl_copy_core.Exec_algo.sexp_of_t engine)
               : bool)]);
  [%expect
    {|
    (immediate (same true))
    (twap (same true))
    (vwap (same true))
    (pov (same true))
    (passive (same true))
    (iceberg (same true))
    (adaptive (same true))
    |}]
;;
