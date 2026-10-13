(** The HTTP API of the copy-trading platform. *)

(** EIP-191 [personal_sign] and wallet signature parsing. *)
module Wallet_signature = Wallet_signature

(** HMAC-signed, expiring session tokens. *)
module Session = Session

(** Single-use login challenges in the Sign-In with Ethereum layout. *)
module Challenge = Challenge
