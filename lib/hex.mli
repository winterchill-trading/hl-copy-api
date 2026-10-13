(** Lowercase hex and random bytes. *)

open! Core

val of_bytes : string -> string

(** [n] random bytes from the operating system's generator, as [2n] hex digits. *)
val random : int -> string
