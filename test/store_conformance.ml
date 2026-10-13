open! Core
open! Async
open Hl_copy_api
module Address = Hl_protocol.Address
module Entry = Hl_copy_core.Key_store.Entry

let address c = Address.of_string ("0x" ^ String.make 40 c)
let alice = address '1'
let bob = address '2'
let leader_a = address 'a'
let leader_b = address 'b'
let builder = address 'f'

let record
  ?(scale = Api_types.Scale_mode.Equity_ratio)
  ?(state = Api_types.Follow_state.Running)
  ~follower
  ~leader
  ~created_ms
  ()
  : Follow_record.t
  =
  { id = Follow_record.id ~follower ~leader
  ; follower
  ; leader
  ; scale
  ; caps = Api_types.Caps.default
  ; state
  ; created_ms
  ; updated_ms = created_ms
  }
;;

(* Created times carry nanoseconds on purpose: a store that rounds to microseconds (as
   timestamptz would) breaks the round trip, and the key file the engine reads changes. *)
let entry ?valid_until ~agent ~name ~created_ns () : Entry.t =
  { agent_address = agent
  ; agent_name = name
  ; created = Time_ns.of_int_ns_since_epoch created_ns
  ; valid_until = Option.map valid_until ~f:Time_ns.of_int_ns_since_epoch
  ; ciphertext = "00ff10ab" ^ String.make 56 'c'
  ; nonce = String.init 48 ~f:(fun i -> Char.of_int_exn (Char.to_int 'a' + (i % 6)))
  ; tag = String.make 64 '9'
  }
;;

let ok d = d >>| Or_error.ok_exn
let ids rs = List.map rs ~f:(fun (r : Follow_record.t) -> r.id)
let short id = String.prefix id 5 ^ ".." ^ String.suffix id 2

let print_follows store ?follower () =
  let%map rs = ok (Store.follows ?follower store ()) in
  print_s [%sexp (List.map (ids rs) ~f:short : string list)]
;;

let empty store =
  print_endline "-- empty";
  let%bind r = ok (Store.find_follow store ~id:"nope") in
  let%bind follows = ok (Store.follows store ()) in
  let%bind agent = ok (Store.find_agent store ~account:alice) in
  let%bind agents = ok (Store.agents store) in
  let%map fee = ok (Store.builder_fee_approved store ~account:alice ~builder) in
  print_s
    [%message
      (r : Follow_record.t option)
        (follows : Follow_record.t list)
        (agent : Entry.t option)
        (agents : (Address.t * Entry.t) list)
        (fee : bool)]
;;

let follows store =
  print_endline "-- follows";
  (* Inserted out of order: listing is by creation time, then id. *)
  let a2 = record ~follower:alice ~leader:leader_b ~created_ms:20 () in
  let a1 = record ~follower:alice ~leader:leader_a ~created_ms:10 () in
  let b1 = record ~follower:bob ~leader:leader_a ~created_ms:20 () in
  let%bind () =
    Deferred.List.iter ~how:`Sequential [ a2; b1; a1 ] ~f:(fun r ->
      ok (Store.put_follow store r))
  in
  let%bind () = print_follows store () in
  let%bind () = print_follows store ~follower:alice () in
  let%bind () = print_follows store ~follower:(address '9') () in
  let%bind found = ok (Store.find_follow store ~id:a1.id) in
  print_s
    [%message "" ~round_trip:(Option.equal Follow_record.equal found (Some a1) : bool)];
  (* Every field survives, including the float settings and the allowlist. *)
  let changed =
    { a1 with
      scale = Fixed_notional 1234.5678
    ; caps =
        { max_leverage = 2.5
        ; max_notional_per_symbol = 0.
        ; max_daily_loss = 1e-3
        ; allowlist = [ "BTC"; "kPEPE"; "@107" ]
        ; min_order_notional = 10.
        }
    ; state = Paused
    ; updated_ms = 1_800_000_000_123
    }
  in
  let%bind () = ok (Store.put_follow store changed) in
  (* The same write again is harmless. *)
  let%bind () = ok (Store.put_follow store changed) in
  let%bind found = ok (Store.find_follow store ~id:a1.id) in
  print_s
    [%message "" ~replaced:(Option.equal Follow_record.equal found (Some changed) : bool)];
  let%bind () =
    ok (Store.put_follow store { a2 with scale = Multiplier 0.25; state = Stopped })
  in
  let%bind found = ok (Store.find_follow store ~id:a2.id) in
  print_s
    [%sexp
      (Option.map found ~f:(fun r -> r.scale, r.state)
       : (Api_types.Scale_mode.t * Api_types.Follow_state.t) option)];
  let%bind () = print_follows store ~follower:alice () in
  let%bind added = ok (Store.add_follow_if_absent store a1) in
  let%bind found = ok (Store.find_follow store ~id:a1.id) in
  print_s
    [%message
      "add existing"
        (added : bool)
        ~kept:(Option.equal Follow_record.equal found (Some changed) : bool)];
  let c = record ~follower:bob ~leader:leader_b ~created_ms:5 () in
  let%bind added = ok (Store.add_follow_if_absent store c) in
  print_s [%message "add new" (added : bool)];
  print_follows store ()
;;

let agents store =
  print_endline "-- agents";
  let first =
    entry
      ~agent:(address 'c')
      ~name:"hl-copy valid_until 1807343157720"
      ~created_ns:1_760_000_000_123_456_789
      ~valid_until:1_807_343_157_720_000_000
      ()
  in
  let%bind () = ok (Store.put_agent store ~account:bob first) in
  let%bind () = ok (Store.put_agent store ~account:alice first) in
  let%bind found = ok (Store.find_agent store ~account:alice) in
  print_s [%message "" ~round_trip:(Option.equal Entry.equal found (Some first) : bool)];
  let rotated =
    entry ~agent:(address 'd') ~name:"rotated" ~created_ns:1_760_000_001_000_000_001 ()
  in
  let%bind () = ok (Store.put_agent store ~account:alice rotated) in
  let%bind () = ok (Store.put_agent store ~account:alice rotated) in
  let%bind found = ok (Store.find_agent store ~account:alice) in
  print_s [%message "" ~rotated:(Option.equal Entry.equal found (Some rotated) : bool)];
  let%bind added = ok (Store.add_agent_if_absent store ~account:alice first) in
  let%bind found = ok (Store.find_agent store ~account:alice) in
  print_s
    [%message
      "add existing"
        (added : bool)
        ~kept:(Option.equal Entry.equal found (Some rotated) : bool)];
  let%bind all = ok (Store.agents store) in
  print_s
    [%sexp
      (List.map all ~f:(fun (a, (e : Entry.t)) ->
         short (Address.to_string a), e.agent_name)
       : (string * string) list)];
  let%bind () = ok (Store.delete_agent store ~account:alice) in
  let%bind () = ok (Store.delete_agent store ~account:alice) in
  let%bind found = ok (Store.find_agent store ~account:alice) in
  let%bind added = ok (Store.add_agent_if_absent store ~account:(address '3') first) in
  let%map all = ok (Store.agents store) in
  print_s
    [%message
      "after delete"
        ~alice:(Option.is_some found : bool)
        ~add_new:(added : bool)
        ~accounts:(List.length all : int)]
;;

let builder_fees store =
  print_endline "-- builder fees";
  let at = Time_ns.of_int_ns_since_epoch 1_760_000_000_000_000_000 in
  let%bind () = ok (Store.approve_builder_fee store ~account:alice ~builder ~at) in
  let%bind () = ok (Store.approve_builder_fee store ~account:alice ~builder ~at) in
  let%bind alice_fee = ok (Store.builder_fee_approved store ~account:alice ~builder) in
  let%bind other_builder =
    ok (Store.builder_fee_approved store ~account:alice ~builder:leader_a)
  in
  let%map bob_fee = ok (Store.builder_fee_approved store ~account:bob ~builder) in
  print_s [%message (alice_fee : bool) (other_builder : bool) (bob_fee : bool)]
;;

let run ~fresh =
  Deferred.List.iter
    ~how:`Sequential
    [ empty; follows; agents; builder_fees ]
    ~f:(fun scenario ->
      let%bind store = fresh () in
      let%bind () = scenario store in
      Store.close store)
;;
