(** Stateless session tokens: [<address>.<issued_ms>.<expires_ms>.<mac>], with [mac] the
    hex HMAC-SHA256 of the first three fields under a server key. The server keeps no
    session table; a token is valid until it expires, and changing the key logs everyone
    out. *)

open! Core
open Hl_protocol

type t

(** [key] should be 32 random bytes ({!Hl_copy_core.Key_store.Master_key.derive}). [ttl]
    defaults to 24 hours. *)
val create : ?ttl:Time_ns.Span.t -> key:string -> unit -> t

val ttl : t -> Time_ns.Span.t

module Claims : sig
  type t =
    { address : Address.t
    ; issued_ms : int
    ; expires_ms : int
    }
  [@@deriving sexp_of, compare, equal]
end

val issue : t -> Address.t -> now:Time_ns.t -> string * Claims.t

(** Fails on a malformed token, a bad MAC (checked in constant time) or [now] at or past
    the expiry. *)
val verify : t -> now:Time_ns.t -> string -> Claims.t Or_error.t

(** The token of an [Authorization: Bearer <token>] header value. *)
val of_authorization_header : string -> string option
