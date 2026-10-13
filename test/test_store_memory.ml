open! Core
open! Async
open Hl_copy_api

let%expect_test "conformance" =
  let%bind () =
    Store_conformance.run ~fresh:(fun () ->
      return (Store_memory.store (Store_memory.create ())))
  in
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
