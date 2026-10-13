(** Hyperliquid's user-signed approvals as the API handles them: the server builds the
    action, the user's wallet signs its EIP-712 typed data, and the server checks the
    signer before forwarding the signed action to the exchange.

    Nothing here holds or sees the user's key. The [approveAgent] and [approveBuilderFee]
    digests are {!Hl_client.Signing.user_action_digest}, the same bytes the wallet signs
    from {!Api_types.Approve_agent.typed_data}. *)

open! Core
open Async
open Hl_protocol

(** {2 Conversions between the web types and the wire types} *)

val address_of_api : Api_types.Address.t -> Address.t
val address_to_api : Address.t -> Api_types.Address.t
val chain_to_api : User_signed_action.Hyperliquid_chain.t -> Api_types.Hyperliquid_chain.t
val approve_agent_action : Api_types.Approve_agent.t -> User_signed_action.t
val approve_builder_fee_action : Api_types.Approve_builder_fee.t -> User_signed_action.t

(** {2 Offers} *)

(** The platform's agent name, ["hl-copy"]. *)
val agent_name_prefix : string

(** 179 days: inside the documented 180-day maximum with a day of margin for clocks. *)
val default_agent_validity : Time_ns.Span.t

val approve_agent_offer
  :  Venue.t
  -> agent_address:Address.t
  -> agent_name:string
  -> nonce:int
  -> Api_types.Approve_agent.t

val approve_builder_fee_offer
  :  Venue.t
  -> builder:Address.t
  -> max_fee_tenths_bp:int
  -> nonce:int
  -> Api_types.Approve_builder_fee.t

(** {2 Checking and submitting} *)

(** Parses the wallet's signature and checks it recovers to [owner] for [action]. Rejects
    a [Mainnet] action outright. *)
val verify
  :  User_signed_action.t
  -> signature:string
  -> owner:Address.t
  -> Hl_client.Signing.Signature.t Or_error.t

(** Posts the signed action to [/exchange]. [X-Address] is [owner], which hl-sim uses only
    when signatures are not checked. An [Err] response becomes an error. *)
val submit
  :  Venue.t
  -> owner:Address.t
  -> User_signed_action.t
  -> Hl_client.Signing.Signature.t
  -> unit Or_error.t Deferred.t
