open! Core
open! Async
open Hl_protocol

module type S = sig
  type t

  val kind : t -> string
  val find_follow : t -> id:string -> Follow_record.t option Or_error.t Deferred.t

  val follows
    :  ?follower:Address.t
    -> t
    -> unit
    -> Follow_record.t list Or_error.t Deferred.t

  val put_follow : t -> Follow_record.t -> unit Or_error.t Deferred.t
  val add_follow_if_absent : t -> Follow_record.t -> bool Or_error.t Deferred.t

  val find_agent
    :  t
    -> account:Address.t
    -> Hl_copy_core.Key_store.Entry.t option Or_error.t Deferred.t

  val agents
    :  t
    -> (Address.t * Hl_copy_core.Key_store.Entry.t) list Or_error.t Deferred.t

  val put_agent
    :  t
    -> account:Address.t
    -> Hl_copy_core.Key_store.Entry.t
    -> unit Or_error.t Deferred.t

  val add_agent_if_absent
    :  t
    -> account:Address.t
    -> Hl_copy_core.Key_store.Entry.t
    -> bool Or_error.t Deferred.t

  val delete_agent : t -> account:Address.t -> unit Or_error.t Deferred.t

  val builder_fee_approved
    :  t
    -> account:Address.t
    -> builder:Address.t
    -> bool Or_error.t Deferred.t

  val approve_builder_fee
    :  t
    -> account:Address.t
    -> builder:Address.t
    -> at:Time_ns.t
    -> unit Or_error.t Deferred.t

  val close : t -> unit Deferred.t
end

type t = T : (module S with type t = 'a) * 'a -> t

let create m store = T (m, store)
let kind (T ((module M), s)) = M.kind s
let find_follow (T ((module M), s)) ~id = M.find_follow s ~id
let follows ?follower (T ((module M), s)) () = M.follows ?follower s ()
let put_follow (T ((module M), s)) r = M.put_follow s r
let add_follow_if_absent (T ((module M), s)) r = M.add_follow_if_absent s r
let find_agent (T ((module M), s)) ~account = M.find_agent s ~account
let agents (T ((module M), s)) = M.agents s
let put_agent (T ((module M), s)) ~account e = M.put_agent s ~account e

let add_agent_if_absent (T ((module M), s)) ~account e =
  M.add_agent_if_absent s ~account e
;;

let delete_agent (T ((module M), s)) ~account = M.delete_agent s ~account

let builder_fee_approved (T ((module M), s)) ~account ~builder =
  M.builder_fee_approved s ~account ~builder
;;

let approve_builder_fee (T ((module M), s)) ~account ~builder ~at =
  M.approve_builder_fee s ~account ~builder ~at
;;

let close (T ((module M), s)) = M.close s
