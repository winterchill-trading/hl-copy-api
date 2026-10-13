open! Core
open Hl_copy_api

let t0 = Time_ns.epoch
let at sec = Time_ns.add t0 (Time_ns.Span.of_sec sec)

let%expect_test "burst, then the refill rate" =
  let t = Rate_limiter.create ~per_minute:60 ~burst:3 in
  let try_ ~key sec = Rate_limiter.allow t ~key ~now:(at sec) in
  print_s [%sexp (List.map [ 0.; 0.; 0.; 0. ] ~f:(try_ ~key:"a") : bool list)];
  [%expect {| (true true true false) |}];
  (* Another client has its own bucket. *)
  print_s [%sexp (try_ ~key:"b" 0. : bool)];
  [%expect {| true |}];
  (* One token per second comes back. *)
  print_s
    [%sexp (List.map [ 0.5; 1.0; 1.0; 3.5; 3.5; 3.5 ] ~f:(try_ ~key:"a") : bool list)];
  [%expect {| (false true false true true false) |}]
;;

let%test_unit "never more than burst + rate * elapsed" =
  Quickcheck.test
    ~sexp_of:[%sexp_of: int list]
    (Quickcheck.Generator.list (Int.gen_incl 0 2_000))
    ~f:(fun gaps_ms ->
      let t = Rate_limiter.create ~per_minute:120 ~burst:5 in
      let now = ref t0 in
      let allowed =
        List.count gaps_ms ~f:(fun gap ->
          now := Time_ns.add !now (Time_ns.Span.of_int_ms gap);
          Rate_limiter.allow t ~key:"k" ~now:!now)
      in
      let elapsed = Time_ns.Span.to_sec (Time_ns.diff !now t0) in
      assert (Float.( <= ) (Float.of_int allowed) (5. +. (2. *. elapsed) +. 1e-9)))
;;
