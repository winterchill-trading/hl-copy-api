(** The HTTP API of the copy-trading platform. *)

(** EIP-191 [personal_sign] and wallet signature parsing. *)
module Wallet_signature = Wallet_signature

(** HMAC-signed, expiring session tokens. *)
module Session = Session

(** Single-use login challenges in the Sign-In with Ethereum layout. *)
module Challenge = Challenge

(** The exchange approvals go to; mainnet is refused. *)
module Venue = Venue

(** [approveAgent] and [approveBuilderFee]: offers, signer checks, submission. *)
module Approvals = Approvals

(** Per-user agent key offers and approvals, builder fee approvals. *)
module Agents = Agents
