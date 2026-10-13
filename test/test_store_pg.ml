open! Core
open! Async
open Hl_copy_api

let connect () =
  let%bind database_url = Test_db.fresh_url () in
  Store_pg.connect ~database_url () >>| Or_error.ok_exn
;;

let%expect_test "conformance" =
  let%bind () = Store_conformance.run ~fresh:(fun () -> connect () >>| Store_pg.store) in
  [%expect
    {|
    -- empty
    ((r ()) (follows ()) (agent ()) (agents ()) (fee false))
    -- follows
    (0x111..aa 0x111..bb 0x222..aa)
    (0x111..aa 0x111..bb)
    ()
    (round_trip true)
    (replaced true)
    (((Multiplier 0.25) Stopped))
    (0x111..aa 0x111..bb)
    ("add existing" (added false) (kept true))
    ("add new" (added true))
    (0x222..bb 0x111..aa 0x111..bb 0x222..aa)
    -- agents
    (round_trip true)
    (rotated true)
    ("add existing" (added false) (kept true))
    ((0x111..11 rotated) (0x222..22 "hl-copy valid_until 1807343157720"))
    ("after delete" (alice false) (add_new true) (accounts 2))
    -- builder fees
    ((alice_fee true) (other_builder false) (bob_fee false))
    |}];
  return ()
;;

let%expect_test "migrations apply once, so replicas can share the database" =
  let%bind database_url = Test_db.fresh_url () in
  let connect () = Store_pg.connect ~database_url () >>| Or_error.ok_exn in
  let%bind first = connect () in
  let%bind second = connect () in
  print_s
    [%message
      ""
        ~first:(Store_pg.applied_migrations first : int list)
        ~second:(Store_pg.applied_migrations second : int list)];
  [%expect {| ((first (1)) (second ())) |}];
  let%bind () = Store_pg.close first in
  Store_pg.close second
;;

let%expect_test "an entry that is not hex is refused before any SQL" =
  let%bind t = connect () in
  let entry : Hl_copy_core.Key_store.Entry.t =
    { agent_address = Hl_protocol.Address.of_string ("0x" ^ String.make 40 'c')
    ; agent_name = "bad"
    ; created = Time_ns.epoch
    ; valid_until = None
    ; ciphertext = "zz"
    ; nonce = ""
    ; tag = ""
    }
  in
  let%bind r =
    Store_pg.put_agent
      t
      ~account:(Hl_protocol.Address.of_string ("0x" ^ String.make 40 '1'))
      entry
  in
  print_s [%sexp (r : unit Or_error.t)];
  [%expect
    {|
    (Error
     ("store: put_agent" ("expected an even number of hex digits" (hex zz))))
    |}];
  Store_pg.close t
;;

let%expect_test "an unreachable database fails at connect" =
  let%bind r =
    Store_pg.connect
      ~database_url:"postgres://nobody@127.0.0.1:1/none?sslmode=disable&connect_timeout=2"
      ()
  in
  print_s [%sexp (Result.is_error r : bool)];
  [%expect {| true |}];
  return ()
;;
