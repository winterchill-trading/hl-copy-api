(** The engine's [GET /status], read for [/me] and [/ws].

    hl-copy-engine is being written in parallel, so this decoder is deliberately lenient
    and accepts the shape below; any missing field gets a neutral default, and an engine
    that is down or answers something else gives {!empty} (the API still works, with zero
    pnl and no per-follow positions).

    {v
{"followers": [
  {"follower": "0x...", "leader": "0x...",
   "state": "running",                 (optional, informative)
   "pnl": 12.5,                        (USD attributed to the follow; number or string)
   "positions": [{"coin": "BTC", "size": 0.01, "entry_px": 100000,
                  "unrealized_pnl": 1.2, "leverage": 3}],
   "last_error": "..."}                (optional)
]}
    v} *)

open! Core
open Async
open Hl_protocol

module Follow_status : sig
  type t =
    { follower : Address.t
    ; leader : Address.t
    ; state : string option
    ; pnl : float
    ; positions : Api_types.Position.t list
    ; last_error : string option
    }
  [@@deriving sexp_of]
end

type t = Follow_status.t list [@@deriving sexp_of]

val empty : t
val of_json : Yojson.Safe.t -> t
val find : t -> follower:Address.t -> leader:Address.t -> Follow_status.t option

(** [GET <base_url>/status] with a short timeout (default 2 s); {!empty} on any failure. *)
val fetch : ?timeout:Time_ns.Span.t -> Uri.t option -> t Deferred.t
