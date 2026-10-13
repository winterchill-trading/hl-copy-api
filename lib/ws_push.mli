(** Messages pushed on [GET /ws], one JSON object per text frame:

    - [{"type": "me", "me": <Api_types.Me>}]: on connect and every status interval;
    - [{"type": "follow", "follow": <Api_types.Follow>}]: when a follow changes;
    - [{"type": "fill", "fill": <Api_types.Fill>}]: each new fill of the user's account;
    - [{"type": "error", "error": "..."}].

    Defined here until the web app adopts it into [Api_types]. *)

open! Core

type t =
  | Me of Api_types.Me.t
  | Follow of Api_types.Follow.t
  | Fill of Api_types.Fill.t
  | Error of string
[@@deriving sexp_of]

val to_json : t -> Yojson.Safe.t
val to_string : t -> string
