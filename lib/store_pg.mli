(** {!Store.S} on PostgreSQL through pg-async: tables [follows], [agents] and
    [builder_fee_approvals] (see [migrations/]). The only module with SQL in it. *)

open! Core
open! Async
include Store.S

(** Connects a pool to [database_url] ([postgres://user:pass@host:port/db?sslmode=...]),
    or to what [DATABASE_URL] / [PG*] say when it is omitted, and applies pending
    migrations (under an advisory lock, so several replicas may start at once). TLS is
    required unless the URL says [sslmode=disable]. *)
val connect
  :  ?database_url:string
  -> ?max_connections:int (** default 4 *)
  -> unit
  -> t Or_error.t Deferred.t

(** The migrations this [connect] applied (empty when the schema was current). *)
val applied_migrations : t -> int list

val store : t -> Store.t
