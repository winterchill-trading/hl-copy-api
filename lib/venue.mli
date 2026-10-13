(** Where approvals are submitted: hl-sim or Hyperliquid testnet, never mainnet.

    {!create} refuses any host under [hyperliquid.xyz] (the mainnet API is
    [api.hyperliquid.xyz]; testnet is [api.hyperliquid-testnet.xyz], another domain), and
    every action is signed for [hyperliquidChain = "Testnet"], which the exchange will not
    accept on mainnet. hl-sim accepts either chain. *)

open! Core

type t

val create : ?signature_chain_id:string -> base_url:Uri.t -> unit -> t Or_error.t

(** Whether [uri] points at the mainnet API. *)
val is_mainnet_url : Uri.t -> bool

val config : t -> Hl_client.Config.t
val base_url : t -> Uri.t

(** Always [Testnet]. *)
val hyperliquid_chain : t -> Hl_protocol.User_signed_action.Hyperliquid_chain.t

(** Default ["0x66eee"], what the SDK signs with. *)
val signature_chain_id : t -> string
