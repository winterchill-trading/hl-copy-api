(** An in-process hl-sim on a free port, verifying every signature. *)

open! Core
open! Async

type t =
  { server : Hl_sim.Server.t
  ; base_url : Uri.t
  ; close : unit -> unit Deferred.t
  }

val start : unit -> t Deferred.t
val with_sim : (t -> 'a Deferred.t) -> 'a Deferred.t

(** A throwaway wallet key generated for the test. *)
val wallet_key : int -> Hl_client.Signing.Private_key.t

(** A fresh temporary directory, removed by [with_dir]. *)
val with_dir : (string -> 'a Deferred.t) -> 'a Deferred.t
