open! Core
open! Async
open Hl_protocol
module Entry = Hl_copy_core.Key_store.Entry

type t =
  { follows : Follow_record.t String.Table.t
  ; agents : Entry.t Address.Table.t
  ; builder_fees : Time_ns.t Hashtbl.M(Address).t Address.Table.t
  }

let kind _ = "memory"

let create () =
  { follows = String.Table.create ()
  ; agents = Address.Table.create ()
  ; builder_fees = Address.Table.create ()
  }
;;

let find_follow t ~id = return (Ok (Hashtbl.find t.follows id))

let follows ?follower t () =
  Hashtbl.data t.follows
  |> List.filter ~f:(fun (r : Follow_record.t) ->
    Option.value_map follower ~default:true ~f:(Address.equal r.follower))
  |> List.sort ~compare:Follow_record.compare_by_age
  |> Or_error.return
  |> return
;;

let put_follow t (r : Follow_record.t) =
  Hashtbl.set t.follows ~key:r.id ~data:r;
  return (Ok ())
;;

let add_follow_if_absent t (r : Follow_record.t) =
  return
    (Ok
       (match Hashtbl.add t.follows ~key:r.id ~data:r with
        | `Ok -> true
        | `Duplicate -> false))
;;

let find_agent t ~account = return (Ok (Hashtbl.find t.agents account))

let agents t =
  Hashtbl.to_alist t.agents
  |> List.sort ~compare:(fun (a, _) (b, _) -> Address.compare a b)
  |> Or_error.return
  |> return
;;

let put_agent t ~account entry =
  Hashtbl.set t.agents ~key:account ~data:entry;
  return (Ok ())
;;

let add_agent_if_absent t ~account entry =
  return
    (Ok
       (match Hashtbl.add t.agents ~key:account ~data:entry with
        | `Ok -> true
        | `Duplicate -> false))
;;

let delete_agent t ~account =
  Hashtbl.remove t.agents account;
  return (Ok ())
;;

let builder_fee_approved t ~account ~builder =
  return
    (Ok
       (match Hashtbl.find t.builder_fees account with
        | Some builders -> Hashtbl.mem builders builder
        | None -> false))
;;

let approve_builder_fee t ~account ~builder ~at =
  let builders =
    Hashtbl.find_or_add t.builder_fees account ~default:(fun () ->
      Hashtbl.create (module Address))
  in
  ignore (Hashtbl.add builders ~key:builder ~data:at : [ `Ok | `Duplicate ]);
  return (Ok ())
;;

let close _ = return ()

let store t =
  Store.create
    (module struct
      type nonrec t = t

      let kind = kind
      let find_follow = find_follow
      let follows = follows
      let put_follow = put_follow
      let add_follow_if_absent = add_follow_if_absent
      let find_agent = find_agent
      let agents = agents
      let put_agent = put_agent
      let add_agent_if_absent = add_agent_if_absent
      let delete_agent = delete_agent
      let builder_fee_approved = builder_fee_approved
      let approve_builder_fee = approve_builder_fee
      let close = close
    end)
    t
;;
