open! Core
open Async
open Hl_protocol
module Key_store = Hl_copy_core.Key_store
module Signing = Hl_client.Signing

module Builder = struct
  type t =
    { address : Address.t
    ; max_fee_tenths_bp : int
    }
  [@@deriving sexp_of]
end

module Pending = struct
  type t =
    { agent_address : Address.t
    ; agent_name : string
    ; nonce : int
    ; created : Time_ns.t
    ; valid_until : Time_ns.t
    }
  [@@deriving sexp_of]
end

type t =
  { key_store : Key_store.t
  ; venue : Venue.t
  ; builder : Builder.t option
  ; agent_validity : Time_ns.Span.t
  ; pending : (Pending.t * string) Address.Table.t (** with the private key, hex *)
  ; builder_offers : Api_types.Approve_builder_fee.t Address.Table.t
  ; builder_approved : Address.Hash_set.t
  ; mutable last_nonce : int
  }

let create ?(agent_validity = Approvals.default_agent_validity) ?builder ~key_store venue =
  { key_store
  ; venue
  ; builder
  ; agent_validity
  ; pending = Address.Table.create ()
  ; builder_offers = Address.Table.create ()
  ; builder_approved = Address.Hash_set.create ()
  ; last_nonce = 0
  }
;;

let key_store t = t.key_store
let offer_reuse_window = Time_ns.Span.of_hr 1.
let ms time = Time_ns.to_int_ns_since_epoch time / 1_000_000

(* Hyperliquid keeps the nonces each signer has used, so two actions the same wallet signs
   (an agent offer and a builder fee offer made in one millisecond, or two offers in a
   row) must never share one. *)
let next_nonce t ~now =
  let nonce = Int.max (ms now) (t.last_nonce + 1) in
  t.last_nonce <- nonce;
  nonce
;;

(* Not every 32-byte string is a valid secp256k1 secret (zero, or at least the group
   order); the chance is about 2^-128, but retrying costs nothing. *)
let rec generate_key () =
  let hex = Hex.random 32 in
  match Signing.Private_key.of_hex hex with
  | Ok key -> hex, key
  | Error _ -> generate_key ()
;;

let fresh t ~now = Time_ns.Span.( < ) (Time_ns.diff now t) offer_reuse_window

let pending_or_new t ~owner ~now =
  match Hashtbl.find t.pending owner with
  | Some ((p : Pending.t), _) when fresh p.created ~now -> Ok p
  | Some _ | None ->
    let open Or_error.Let_syntax in
    let hex, key = generate_key () in
    let valid_until = Time_ns.add now t.agent_validity in
    let%map agent_name =
      Hl_client.Exchange.agent_name ~now ~valid_until Approvals.agent_name_prefix
    in
    let p =
      { Pending.agent_address = Signing.Private_key.address key
      ; agent_name
      ; nonce = next_nonce t ~now
      ; created = now
      ; valid_until
      }
    in
    Hashtbl.set t.pending ~key:owner ~data:(p, hex);
    p
;;

let offer t ~owner ~now =
  let open Or_error.Let_syntax in
  let%map p = pending_or_new t ~owner ~now in
  let approve_builder_fee =
    Option.map t.builder ~f:(fun b ->
      match Hashtbl.find t.builder_offers owner with
      | Some offer
        when Float.( < )
               (Float.of_int (ms now) -. offer.nonce)
               (Time_ns.Span.to_ms offer_reuse_window) -> offer
      | Some _ | None ->
        let offer =
          Approvals.approve_builder_fee_offer
            t.venue
            ~builder:b.address
            ~max_fee_tenths_bp:b.max_fee_tenths_bp
            ~nonce:(next_nonce t ~now)
        in
        Hashtbl.set t.builder_offers ~key:owner ~data:offer;
        offer)
  in
  { Api_types.Agent_offer.approve_agent =
      Approvals.approve_agent_offer
        t.venue
        ~agent_address:p.agent_address
        ~agent_name:p.agent_name
        ~nonce:p.nonce
  ; approve_builder_fee
  }
;;

let check_matches
  ~(expected : Api_types.Approve_agent.t)
  (signed : Api_types.Approve_agent.t)
  =
  if Api_types.Approve_agent.equal
       expected
       { signed with signature_chain_id = expected.signature_chain_id }
  then Ok ()
  else
    Or_error.error_s
      [%message
        "approveAgent does not match the pending offer"
          (expected : Api_types.Approve_agent.t)
          (signed : Api_types.Approve_agent.t)]
;;

let approve_agent t ~owner ?signed ~signature () =
  let open Deferred.Or_error.Let_syntax in
  let%bind (p : Pending.t), private_key =
    match Hashtbl.find t.pending owner with
    | None -> Deferred.Or_error.error_string "no pending agent; request an offer first"
    | Some pending -> return pending
  in
  let expected =
    Approvals.approve_agent_offer
      t.venue
      ~agent_address:p.agent_address
      ~agent_name:p.agent_name
      ~nonce:p.nonce
  in
  let signed = Option.value signed ~default:expected in
  let%bind () = Deferred.return (check_matches ~expected signed) in
  let action = Approvals.approve_agent_action signed in
  let%bind signature = Deferred.return (Approvals.verify action ~signature ~owner) in
  let%bind () = Approvals.submit t.venue ~owner action signature in
  let%map entry =
    Deferred.return
      (Key_store.put
         t.key_store
         ~account:owner
         ~agent_address:p.agent_address
         ~agent_name:p.agent_name
         ~created:p.created
         ~valid_until:p.valid_until
         ~private_key
         ())
  in
  Hashtbl.remove t.pending owner;
  entry
;;

let approve_builder_fee t ~owner ?signed ~signature () =
  let open Deferred.Or_error.Let_syntax in
  let%bind expected =
    match Hashtbl.find t.builder_offers owner with
    | Some offer -> return offer
    | None -> Deferred.Or_error.error_string "no pending builder fee offer"
  in
  let signed = Option.value signed ~default:expected in
  let%bind () =
    if Api_types.Approve_builder_fee.equal
         expected
         { signed with signature_chain_id = expected.signature_chain_id }
    then return ()
    else
      Deferred.Or_error.error_string "approveBuilderFee does not match the pending offer"
  in
  let action = Approvals.approve_builder_fee_action signed in
  let%bind signature = Deferred.return (Approvals.verify action ~signature ~owner) in
  let%map () = Approvals.submit t.venue ~owner action signature in
  Hashtbl.remove t.builder_offers owner;
  Hash_set.add t.builder_approved owner
;;

let active t ~owner =
  Key_store.find t.key_store ~account:owner |> Result.ok |> Option.join
;;

let pending t ~owner = Option.map (Hashtbl.find t.pending owner) ~f:fst

let revoke t ~owner =
  match active t ~owner with
  | None -> Or_error.error_string "no active agent"
  | Some _ -> Key_store.revoke t.key_store ~account:owner
;;

let builder_fee_approved t ~owner = Hash_set.mem t.builder_approved owner
