(** The HTTP API of the copy-trading platform. *)

(** EIP-191 [personal_sign] and wallet signature parsing. *)
module Wallet_signature = Wallet_signature

(** HMAC-signed, expiring session tokens. *)
module Session = Session
