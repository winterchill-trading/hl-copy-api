(** One follow as the API keeps it: which leader a user copies, how (the web form's scale
    mode and caps, the execution algorithm), whether the copy is running, and when it was
    created and last changed. Stopped follows are kept so the dashboard can show them. *)

open! Core
open Hl_protocol

type t =
  { id : string (** ["<follower>-<leader>"]; a user follows a leader at most once *)
  ; follower : Address.t
  ; leader : Address.t
  ; scale : Api_types.Scale_mode.t
  ; caps : Api_types.Caps.t
  ; state : Api_types.Follow_state.t
  ; created_ms : int
  ; updated_ms : int
  ; algo : string option
  (** the execution algorithm in execution-algos' short form, as {!Exec_algo_spec}
      normalizes it; [None] is immediate. Left out of the sexp when [None], so records
      written before it existed read unchanged. *)
  }
[@@deriving sexp, compare, equal]

val id : follower:Address.t -> leader:Address.t -> string

(** Oldest first, then by id. *)
val compare_by_age : t -> t -> int
