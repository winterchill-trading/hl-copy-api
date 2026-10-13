(** Shared steps for the end-to-end tests: an API on top of an in-process hl-sim, wallet
    login and agent approval as the browser does them. *)

open! Core
open! Async

val master : Hl_copy_core.Key_store.Master_key.t

val with_api
  :  ?configure:(Hl_copy_api.Server.Config.t -> Hl_copy_api.Server.Config.t)
  -> (sim:Sim.t
      -> api:Hl_copy_api.Server.t
      -> client:Api_client.t
      -> dir:string
      -> 'a Deferred.t)
  -> 'a Deferred.t

(** Challenge, [personal_sign], verify; returns the session token. *)
val login : Api_client.t -> Hl_client.Signing.Private_key.t -> string Deferred.t

(** [/agent/new] then [/agent/approved] with the wallet's signature. *)
val approve_agent
  :  Api_client.t
  -> token:string
  -> Hl_client.Signing.Private_key.t
  -> unit Deferred.t

(** The active agent's key, read back from the store the way the engine does. *)
val agent_key
  :  dir:string
  -> owner:Hl_protocol.Address.t
  -> Hl_client.Signing.Private_key.t
