(** Wallet signatures as browsers return them, and EIP-191 [personal_sign].

    [personal_sign] (EIP-191 version [0x45]) signs
    [keccak256("\x19Ethereum Signed Message:\n" ^ decimal byte length ^ message)]. Wallets
    return the signature as [0x] plus 130 hex digits: [r] (32 bytes), [s] (32 bytes), [v]
    (1 byte, [27]/[28], or [0]/[1] from some hardware wallets). *)

open! Core
open Hl_protocol

(** The 32-byte digest [personal_sign] signs for [message]. *)
val personal_message_digest : string -> string

(** Parses the 65-byte hex form; [v] in [{0, 1}] is normalised to [{27, 28}]. *)
val of_hex : string -> Hl_client.Signing.Signature.t Or_error.t

(** The 65-byte hex form, [v] as [27]/[28]. *)
val to_hex : Hl_client.Signing.Signature.t -> string

(** The address that signed [message] with [personal_sign]. *)
val recover_personal : message:string -> string -> Address.t Or_error.t

(** Signs like a wallet's [personal_sign]; for tests and scripts. *)
val sign_personal : Hl_client.Signing.Private_key.t -> string -> string

(** The digest [eth_signTypedData_v4] signs for Hyperliquid's user-signed actions: flat
    [string], [address] and [uint64] fields in the [HyperliquidSignTransaction] domain, as
    [Api_types.Approve_agent.typed_data] builds them. Typed data for any
    [hyperliquidChain] other than ["Testnet"] is an error. *)
val typed_data_digest : Yojson.Safe.t -> string Or_error.t

(** Signs like a wallet's [eth_signTypedData_v4]; for tests and scripts. *)
val sign_typed_data
  :  Hl_client.Signing.Private_key.t
  -> Yojson.Safe.t
  -> string Or_error.t
