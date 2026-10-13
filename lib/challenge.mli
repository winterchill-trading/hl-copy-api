(** Login challenges: single-use nonces with a short expiry, kept in memory (a restart
    only forces a new challenge).

    The message follows the EIP-4361 ("Sign-In with Ethereum") layout so wallets display
    it as a sign-in request:

    {v
<domain> wants you to sign in with your Ethereum account:
<EIP-55 checksummed address>

Sign in to hl-copy. This request does not trigger a transaction or cost any fee.

URI: <uri>
Version: 1
Chain ID: <chain id>
Nonce: <nonce>
Issued At: <ISO 8601>
Expiration Time: <ISO 8601>
    v} *)

open! Core
open Hl_protocol

type t

(** [ttl] defaults to five minutes. At most [max_outstanding] (default 100_000) challenges
    are kept; past that the oldest are dropped. *)
val create
  :  ?ttl:Time_ns.Span.t
  -> ?max_outstanding:int
  -> domain:string
  -> uri:string
  -> chain_id:int
  -> unit
  -> t

(** [nonce] is for tests; by default 16 random hex digits. *)
val issue : ?nonce:string -> t -> Address.t -> now:Time_ns.t -> Api_types.Auth.Challenge.t

(** Removes the challenge (it is single-use whatever happens next) and returns its
    message. Without [nonce], the newest outstanding challenge of [address]. Fails when
    there is none, it was issued to another address, or it has expired. *)
val consume : t -> Address.t -> nonce:string option -> now:Time_ns.t -> string Or_error.t

val outstanding : t -> int

(** EIP-55 mixed-case checksum encoding. *)
val checksum_address : Address.t -> string
