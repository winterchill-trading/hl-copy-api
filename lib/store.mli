(** Where the API keeps its state, in domain types: follow records, each account's sealed
    agent key (the {!Hl_copy_core.Key_store.Entry.t}, still encrypted) and builder fee
    approvals.

    Two implementations: {!Store_memory} (tests and [-memory-store]) and {!Store_pg}
    (PostgreSQL, the default). Nothing outside [store_pg.ml] and [migrations/] knows about
    SQL or tables, and the conformance suite in [test/] runs the same scenarios against
    both.

    Every write is keyed and idempotent: a follow by its id, an agent by its account, a
    builder fee by account and builder. Repeating a write leaves the same state, so a
    caller may retry after a timeout. Session tokens and login challenges are not stored:
    tokens are stateless HMACs ({!Session}) and challenges live for five minutes in memory
    ({!Challenge}). *)

open! Core
open! Async
open Hl_protocol

module type S = sig
  type t

  (** ["memory"] or ["postgres"], for logs. *)
  val kind : t -> string

  val find_follow : t -> id:string -> Follow_record.t option Or_error.t Deferred.t

  (** Every follow, or [follower]'s, oldest first ({!Follow_record.compare_by_age}). *)
  val follows
    :  ?follower:Address.t
    -> t
    -> unit
    -> Follow_record.t list Or_error.t Deferred.t

  (** Inserts or replaces the follow with this id. *)
  val put_follow : t -> Follow_record.t -> unit Or_error.t Deferred.t

  (** Inserts the follow unless one with this id exists; [true] when inserted. *)
  val add_follow_if_absent : t -> Follow_record.t -> bool Or_error.t Deferred.t

  val find_agent
    :  t
    -> account:Address.t
    -> Hl_copy_core.Key_store.Entry.t option Or_error.t Deferred.t

  (** Every account with an agent, sorted by account. *)
  val agents
    :  t
    -> (Address.t * Hl_copy_core.Key_store.Entry.t) list Or_error.t Deferred.t

  (** Inserts or replaces the account's agent (a rotation replaces it). *)
  val put_agent
    :  t
    -> account:Address.t
    -> Hl_copy_core.Key_store.Entry.t
    -> unit Or_error.t Deferred.t

  (** Inserts the agent unless the account has one; [true] when inserted. *)
  val add_agent_if_absent
    :  t
    -> account:Address.t
    -> Hl_copy_core.Key_store.Entry.t
    -> bool Or_error.t Deferred.t

  (** [Ok ()] when the account had no agent. *)
  val delete_agent : t -> account:Address.t -> unit Or_error.t Deferred.t

  val builder_fee_approved
    :  t
    -> account:Address.t
    -> builder:Address.t
    -> bool Or_error.t Deferred.t

  (** Records that [account] approved [builder]'s fee; [at] is kept from the first call. *)
  val approve_builder_fee
    :  t
    -> account:Address.t
    -> builder:Address.t
    -> at:Time_ns.t
    -> unit Or_error.t Deferred.t

  val close : t -> unit Deferred.t
end

(** A store of either implementation. *)
type t

val create : (module S with type t = 'a) -> 'a -> t

include S with type t := t
