open! Core
open! Async
open Hl_protocol
module Follower_config = Hl_copy_core.Follower_config
module Record = Follow_record

type t =
  { store : Store.t
  ; config_dir : string
  }

(* The directory is created up front: the engine watches [config_dir] from its own
   container (read-only mount) and reports it as an error until it exists. *)
let create ~store ~config_dir =
  Core_unix.mkdir_p config_dir;
  { store; config_dir }
;;

let config_dir t = t.config_dir
let id = Follow_record.id

(* The web form sends USD amounts as floats (see Api_types); this is the one place they
   become fixed-point. [of_float] raises on NaN, infinity and out-of-range input, which
   [follower_config] turns into an error. *)
let usd x = (Hl_copy_core.Usd.of_float [@alert "-lossy"]) x
let cap x = if Float.( > ) x 0. then Some x else None

let follower_config_exn (r : Record.t) =
  let mode : Hl_copy_core.Scale.Mode.t =
    match r.scale with
    | Equity_ratio -> Equity_ratio
    | Multiplier k -> Multiplier k
    | Fixed_notional n -> Fixed_notional (usd n)
  in
  let caps : Hl_copy_core.Caps.t =
    { max_leverage = cap r.caps.max_leverage
    ; max_notional_per_symbol = Option.map (cap r.caps.max_notional_per_symbol) ~f:usd
    ; max_daily_loss = Option.map (cap r.caps.max_daily_loss) ~f:usd
    ; allowlist =
        (match r.caps.allowlist with
         | [] -> None
         | coins -> Some (List.map coins ~f:Market_data.Symbol.of_string))
    ; min_order_notional = usd r.caps.min_order_notional
    }
  in
  let config =
    Follower_config.create ~mode ~caps ~follower:r.follower ~leader:r.leader ()
  in
  let config =
    { config with
      paused =
        (match r.state with
         | Running -> false
         | Paused | Stopped -> true)
    }
  in
  Or_error.map (Follower_config.validate config) ~f:(fun () -> config)
;;

let follower_config r =
  Or_error.try_with_join (fun () -> follower_config_exn r)
  |> Or_error.tag ~tag:"invalid follow settings"
;;

let write_atomically ~dir ~name contents =
  Or_error.try_with (fun () ->
    Core_unix.mkdir_p dir;
    let tmp = dir ^/ "." ^ name ^ ".tmp" in
    Out_channel.write_all tmp ~data:contents;
    Core_unix.rename ~src:tmp ~dst:(dir ^/ name))
;;

let read_file path =
  match In_channel.read_all path with
  | contents -> Some contents
  | exception _ -> None
;;

(* The engine's view of one record: its config file while running or paused, no file once
   stopped. An identical file is left alone, so a resync at startup does not touch files
   the engine already has. *)
let write_config t (r : Record.t) =
  let open Or_error.Let_syntax in
  let%bind config = follower_config r in
  let name = Follower_config.file_name config in
  let path = t.config_dir ^/ name in
  match r.state with
  | Running | Paused ->
    let contents = Follower_config.to_file_contents config in
    if Option.equal String.equal (read_file path) (Some contents)
    then Ok ()
    else write_atomically ~dir:t.config_dir ~name contents
  | Stopped ->
    Or_error.try_with (fun () ->
      match Sys_unix.file_exists path with
      | `Yes -> Core_unix.unlink path
      | `No | `Unknown -> ())
;;

(* The store is the record of truth and is written first; a config file that then fails to
   write is put right by [sync_configs] at the next start. *)
let save t (r : Record.t) =
  let open Deferred.Or_error.Let_syntax in
  let%bind (_ : Follower_config.t) = Deferred.return (follower_config r) in
  let%bind () = Store.put_follow t.store r in
  Deferred.return (write_config t r)
;;

let start t ~follower ~leader ~scale ~caps ~now_ms =
  let open Deferred.Or_error.Let_syntax in
  let id = id ~follower ~leader in
  match%bind Store.find_follow t.store ~id with
  | Some { state = Running | Paused; _ } ->
    Deferred.Or_error.error_s [%message "already following this leader" (id : string)]
  | existing ->
    let created_ms =
      Option.value_map existing ~default:now_ms ~f:(fun (r : Record.t) -> r.created_ms)
    in
    let record =
      { Record.id
      ; follower
      ; leader
      ; scale
      ; caps
      ; state = Running
      ; created_ms
      ; updated_ms = now_ms
      }
    in
    let%map () = save t record in
    record
;;

let all t = Store.follows t.store ()
let list t ~follower = Store.follows t.store ~follower ()

(* Ids come from URLs; anything that is not "<address>-<address>" is not looked up. *)
let is_id id =
  String.length id = 85
  && String.for_all id ~f:(fun c -> Char.is_alphanum c || Char.equal c '-')
;;

let find t ~follower id =
  if not (is_id id)
  then Deferred.Or_error.return None
  else
    Store.find_follow t.store ~id
    |> Deferred.Or_error.map
         ~f:(Option.filter ~f:(fun (r : Record.t) -> Address.equal r.follower follower))
;;

let update t ~follower id ?scale ?caps ?state ~now_ms () =
  let open Deferred.Or_error.Let_syntax in
  match%bind find t ~follower id with
  | None -> Deferred.Or_error.error_s [%message "no such follow" (id : string)]
  | Some { state = Stopped; _ } ->
    Deferred.Or_error.error_s
      [%message "follow is stopped; follow the leader again" (id : string)]
  | Some r ->
    let record =
      { r with
        scale = Option.value scale ~default:r.scale
      ; caps = Option.value caps ~default:r.caps
      ; state = Option.value state ~default:r.state
      ; updated_ms = now_ms
      }
    in
    let%map () = save t record in
    record
;;

let sync_configs t =
  let open Deferred.Or_error.Let_syntax in
  let%bind records = all t in
  let%bind () =
    Deferred.return (Or_error.combine_errors_unit (List.map records ~f:(write_config t)))
  in
  (* Config files without a running or paused follow behind them (written by a replica
     whose follow was later stopped elsewhere, or by hand) are removed. Only names shaped
     like follow configs are considered. *)
  let active =
    List.filter_map records ~f:(fun r ->
      match r.state with
      | Running | Paused -> Some (r.id ^ ".sexp")
      | Stopped -> None)
    |> String.Set.of_list
  in
  let%map files =
    Deferred.return (Or_error.try_with (fun () -> Sys_unix.readdir t.config_dir))
  in
  Array.iter files ~f:(fun name ->
    match String.chop_suffix name ~suffix:".sexp" with
    | Some id when is_id id && not (Set.mem active name) ->
      Log.Global.info_s [%message "removing stale follower config" (name : string)];
      (try Core_unix.unlink (t.config_dir ^/ name) with
       | _ -> ())
    | Some _ | None -> ())
;;

let import_records t ~dir =
  match Sys_unix.readdir dir with
  | exception _ -> Deferred.Or_error.return 0
  | files ->
    let records =
      Array.to_list files
      |> List.filter ~f:(fun f -> not (String.is_prefix f ~prefix:"."))
      |> List.filter_map ~f:(String.chop_suffix ~suffix:".sexp")
      |> List.filter_map ~f:(fun id ->
        match Sexp.load_sexp_conv_exn (dir ^/ id ^ ".sexp") Record.t_of_sexp with
        | r -> Some r
        | exception exn ->
          Log.Global.error_s
            [%message "skipping unreadable follow record" (id : string) (exn : exn)];
          None)
    in
    Deferred.Or_error.List.fold records ~init:0 ~f:(fun n r ->
      Deferred.Or_error.map (Store.add_follow_if_absent t.store r) ~f:(fun added ->
        if added then n + 1 else n))
;;
