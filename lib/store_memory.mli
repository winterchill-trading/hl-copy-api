(** {!Store.S} in memory: tests, and [-memory-store] for demos where losing every follow
    and agent on restart is fine. *)

open! Core
include Store.S

val create : unit -> t
val store : t -> Store.t
