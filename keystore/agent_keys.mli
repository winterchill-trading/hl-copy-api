(** Per-user agent keys on disk, sealed with {!Sealed} under the master key.

    One file per user (the account that approved the agent): [<dir>/<owner address>.sexp],
    mode [0600], holding every agent ever generated for that user, newest first. Entries
    are never deleted, so an agent address can never be handed out twice: Hyperliquid may
    prune a deregistered agent's nonce state, and a reused address could let old signed
    actions replay.

    Lifecycle: [Pending] (generated, offered to the wallet) -> [Active] (the user's
    [approveAgent] was accepted by the exchange) -> [Revoked] (replaced by a newer active
    agent, or revoked by the user). At most one entry per user is [Active].

    The API writes these files; the engine reads them with {!active} and {!secret}. Writes
    go to a temporary file renamed into place, so a reader never sees half a file. *)

open! Core
open Hl_protocol

module Status : sig
  type t =
    | Pending
    | Active
    | Revoked
  [@@deriving sexp, compare, equal, enumerate]
end

module Entry : sig
  type t =
    { owner : Address.t
    ; agent_address : Address.t
    ; agent_name : string
    (** exactly as signed, e.g. ["hl-copy valid_until 1760000000000"] *)
    ; nonce : int (** of the offered [approveAgent], epoch ms *)
    ; created_ms : int
    ; valid_until_ms : int option
    ; status : Status.t
    ; sealed_key : string (** hex {!Sealed} box of the 32 secret bytes *)
    }
  [@@deriving sexp, compare, equal]
end

type t

val create : dir:string -> Sealed.Master_key.t -> t
val dir : t -> string

(** [<dir>/<owner>.sexp] *)
val path : t -> owner:Address.t -> string

(** Every agent of [owner], newest first; [[]] when the user has none. *)
val entries : t -> owner:Address.t -> Entry.t list Or_error.t

(** Users with a key file. *)
val owners : t -> Address.t list

(** Seals [secret] (the 32 private key bytes) and records a [Pending] agent. Fails if
    [owner] ever had an agent with this address. *)
val add_pending
  :  t
  -> owner:Address.t
  -> agent_address:Address.t
  -> agent_name:string
  -> nonce:int
  -> created_ms:int
  -> valid_until_ms:int option
  -> secret:string
  -> Entry.t Or_error.t

(** Marks the agent [Active] and every other active agent of [owner] [Revoked]. *)
val activate : t -> owner:Address.t -> agent_address:Address.t -> Entry.t Or_error.t

(** Marks the agent [Revoked]. *)
val revoke : t -> owner:Address.t -> agent_address:Address.t -> Entry.t Or_error.t

val find : t -> owner:Address.t -> agent_address:Address.t -> Entry.t option Or_error.t
val active : t -> owner:Address.t -> Entry.t option Or_error.t

(** The newest [Pending] agent, the one the wallet is expected to sign for. *)
val latest_pending : t -> owner:Address.t -> Entry.t option Or_error.t

(** The 32 secret bytes. The box is bound to the owner and agent address, so an entry
    copied into another user's file does not open. *)
val secret : t -> Entry.t -> string Or_error.t
