(** Writing a stored, still sealed {!Hl_copy_core.Key_store.Entry.t} back to the key store
    file the engine reads, in the layout [Key_store.put] uses (the entry's sexp, mode
    [0600], written to a dot-prefixed temporary file and renamed). [Key_store] itself only
    writes entries it seals, and the API must rewrite files from its database without the
    plaintext key. *)

open! Core
open Hl_protocol

val write
  :  Hl_copy_core.Key_store.t
  -> account:Address.t
  -> Hl_copy_core.Key_store.Entry.t
  -> unit Or_error.t
