open! Core
open Hl_protocol

type t =
  { id : string
  ; follower : Address.t
  ; leader : Address.t
  ; scale : Api_types.Scale_mode.t
  ; caps : Api_types.Caps.t
  ; state : Api_types.Follow_state.t
  ; created_ms : int
  ; updated_ms : int
  ; algo : string option [@sexp.option]
  }
[@@deriving sexp, compare, equal]

let id ~follower ~leader =
  sprintf "%s-%s" (Address.to_string follower) (Address.to_string leader)
;;

let compare_by_age a b =
  match Int.compare a.created_ms b.created_ms with
  | 0 -> String.compare a.id b.id
  | c -> c
;;
