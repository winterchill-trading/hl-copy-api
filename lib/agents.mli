(** Agent keys and builder fees for logged-in users.

    [offer] generates a fresh secp256k1 key and returns the [approveAgent] action for the
    wallet to sign (plus [approveBuilderFee] when the platform has a builder). The key of
    an offer stays in memory only: an unapproved offer is lost on restart, and the user
    asks for a new one. A pending offer younger than {!offer_reuse_window} is offered
    again instead of generating another key, so reloading the page does not pile up keys;
    the same goes for the builder fee offer.

    [approve_agent] checks the wallet's signature, forwards it to the exchange and only
    then seals the key into the shared {!Hl_copy_core.Key_store}, replacing the account's
    previous agent; that file is what the engine trades with. Every nonce handed to one
    wallet is distinct. *)

open! Core
open Async
open Hl_protocol

module Builder : sig
  type t =
    { address : Address.t
    ; max_fee_tenths_bp : int (** perps cap it at 100, i.e. 0.1% *)
    }
  [@@deriving sexp_of]
end

module Pending : sig
  (** The key never appears in the sexp. *)
  type t =
    { agent_address : Address.t
    ; agent_name : string
    ; nonce : int
    ; created : Time_ns.t
    ; valid_until : Time_ns.t
    }
  [@@deriving sexp_of]
end

type t

val create
  :  ?agent_validity:Time_ns.Span.t (** default {!Approvals.default_agent_validity} *)
  -> ?builder:Builder.t
  -> key_store:Hl_copy_core.Key_store.t
  -> Venue.t
  -> t

val key_store : t -> Hl_copy_core.Key_store.t

(** One hour. *)
val offer_reuse_window : Time_ns.Span.t

val offer : t -> owner:Address.t -> now:Time_ns.t -> Api_types.Agent_offer.t Or_error.t

(** [signed] is the action as the wallet signed it (the browser may change
    [signature_chain_id] to the chain it is connected to); without it, the pending offer.
    The agent address, name, nonce and chain must match the pending offer. *)
val approve_agent
  :  t
  -> owner:Address.t
  -> ?signed:Api_types.Approve_agent.t
  -> signature:string
  -> unit
  -> Hl_copy_core.Key_store.Entry.t Or_error.t Deferred.t

(** Like [approve_agent] for the builder fee offered by the latest [offer]. *)
val approve_builder_fee
  :  t
  -> owner:Address.t
  -> ?signed:Api_types.Approve_builder_fee.t
  -> signature:string
  -> unit
  -> unit Or_error.t Deferred.t

(** Deletes the account's key file; the engine stops trading the account. The exchange
    keeps the approval until another agent is approved under the same name or it expires. *)
val revoke : t -> owner:Address.t -> unit Or_error.t

(** The approved agent, from the key store. *)
val active : t -> owner:Address.t -> Hl_copy_core.Key_store.Entry.t option

val pending : t -> owner:Address.t -> Pending.t option

(** Builder fee approved through this process (kept in memory). *)
val builder_fee_approved : t -> owner:Address.t -> bool
