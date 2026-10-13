(** Lowercase hex and random bytes. *)

open! Core

val of_bytes : string -> string

(** Hex digits (either case, no [0x]) to bytes; fails on odd length or a non-hex digit. *)
val to_bytes : string -> string Or_error.t

(** [n] random bytes from the operating system's generator, as [2n] hex digits. *)
val random : int -> string
