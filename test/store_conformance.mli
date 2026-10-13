(** Scenarios every {!Hl_copy_api.Store.S} must pass. [run] prints what it observes; the
    memory and PostgreSQL tests expect the same text. *)

open! Core
open! Async

(** [fresh ()] returns an empty store; each scenario gets its own. *)
val run : fresh:(unit -> Hl_copy_api.Store.t Deferred.t) -> unit Deferred.t
