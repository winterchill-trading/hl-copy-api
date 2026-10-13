(** Agent keys and builder fees for logged-in users.

    [offer] generates a fresh secp256k1 key for the user, seals it into the
    {!Hl_copy_keystore.Agent_keys} store as [Pending] and returns the [approveAgent]
    action for the wallet to sign (plus [approveBuilderFee] when the platform has a
    builder). [approve_agent] checks the wallet's signature, forwards it to the exchange
    and marks the agent [Active]; a previous active agent becomes [Revoked]. A pending
    offer younger than {!offer_reuse_window} is offered again instead of generating
    another key, so reloading the page does not pile up keys; the same goes for the
    builder fee offer. *)

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

type t

val create
  :  ?agent_validity:Time_ns.Span.t (** default {!Approvals.default_agent_validity} *)
  -> ?builder:Builder.t
  -> keys:Hl_copy_keystore.Agent_keys.t
  -> Venue.t
  -> t

val keys : t -> Hl_copy_keystore.Agent_keys.t

(** One hour. *)
val offer_reuse_window : Time_ns.Span.t

val offer : t -> owner:Address.t -> now:Time_ns.t -> Api_types.Agent_offer.t Or_error.t

(** [signed] is the action as the wallet signed it (the browser may change
    [signature_chain_id] to the chain it is connected to); without it, the pending offer.
    The agent address, name, nonce and chain must match the newest pending offer. *)
val approve_agent
  :  t
  -> owner:Address.t
  -> ?signed:Api_types.Approve_agent.t
  -> signature:string
  -> unit
  -> Hl_copy_keystore.Agent_keys.Entry.t Or_error.t Deferred.t

(** Like [approve_agent] for the builder fee offered by the latest [offer]. *)
val approve_builder_fee
  :  t
  -> owner:Address.t
  -> ?signed:Api_types.Approve_builder_fee.t
  -> signature:string
  -> unit
  -> unit Or_error.t Deferred.t

(** Revokes the active agent locally; the engine stops using it. The exchange keeps the
    approval until the user approves another agent under the same name or it expires. *)
val revoke : t -> owner:Address.t -> Hl_copy_keystore.Agent_keys.Entry.t Or_error.t

val active : t -> owner:Address.t -> Hl_copy_keystore.Agent_keys.Entry.t option

(** Builder fee approved through this process (kept in memory). *)
val builder_fee_approved : t -> owner:Address.t -> bool
