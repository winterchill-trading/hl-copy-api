open! Core
open Hl_protocol
module Follower_config = Hl_copy_core.Follower_config

module Record = struct
  type t =
    { id : string
    ; follower : Address.t
    ; leader : Address.t
    ; scale : Api_types.Scale_mode.t
    ; caps : Api_types.Caps.t
    ; state : Api_types.Follow_state.t
    ; created_ms : int
    ; updated_ms : int
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { config_dir : string
  ; state_dir : string
  }

(* Both directories are created up front: the engine watches [config_dir] from its own
   container (read-only mount) and reports it as an error until it exists. *)
let create ~config_dir ~state_dir =
  Core_unix.mkdir_p config_dir;
  Core_unix.mkdir_p state_dir;
  { config_dir; state_dir }
;;

let config_dir t = t.config_dir

let id ~follower ~leader =
  sprintf "%s-%s" (Address.to_string follower) (Address.to_string leader)
;;

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

let record_path t id = t.state_dir ^/ id ^ ".sexp"

let load t id =
  match Sexp.load_sexp_conv_exn (record_path t id) Record.t_of_sexp with
  | record -> Some record
  | exception _ -> None
;;

let save t (r : Record.t) =
  let open Or_error.Let_syntax in
  let%bind config = follower_config r in
  let%bind () =
    match r.state with
    | Running | Paused ->
      write_atomically
        ~dir:t.config_dir
        ~name:(Follower_config.file_name config)
        (Follower_config.to_file_contents config)
    | Stopped ->
      Or_error.try_with (fun () ->
        let path = t.config_dir ^/ Follower_config.file_name config in
        match Sys_unix.file_exists path with
        | `Yes -> Core_unix.unlink path
        | `No | `Unknown -> ())
  in
  write_atomically
    ~dir:t.state_dir
    ~name:(r.id ^ ".sexp")
    (Sexp.to_string_hum (Record.sexp_of_t r) ^ "\n")
;;

let start t ~follower ~leader ~scale ~caps ~now_ms =
  let id = id ~follower ~leader in
  match load t id with
  | Some { state = Running | Paused; _ } ->
    Or_error.error_s [%message "already following this leader" (id : string)]
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
    Or_error.map (save t record) ~f:(fun () -> record)
;;

let all t =
  match Sys_unix.readdir t.state_dir with
  | exception _ -> []
  | files ->
    Array.to_list files
    |> List.filter_map ~f:(String.chop_suffix ~suffix:".sexp")
    |> List.filter ~f:(fun id -> not (String.is_prefix id ~prefix:"."))
    |> List.filter_map ~f:(load t)
    |> List.sort ~compare:(fun (a : Record.t) b ->
      Comparable.lexicographic
        [ (fun (a : Record.t) b -> Int.compare a.created_ms b.created_ms)
        ; (fun a b -> String.compare a.id b.id)
        ]
        a
        b)
;;

let list t ~follower = List.filter (all t) ~f:(fun r -> Address.equal r.follower follower)

let find t ~follower id =
  (* Ids come from URLs; anything that is not "<address>-<address>" never touches the file
     system. *)
  let is_id =
    String.length id = 85
    && String.for_all id ~f:(fun c -> Char.is_alphanum c || Char.equal c '-')
  in
  if not is_id
  then None
  else
    Option.filter (load t id) ~f:(fun (r : Record.t) -> Address.equal r.follower follower)
;;

let update t ~follower id ?scale ?caps ?state ~now_ms () =
  match find t ~follower id with
  | None -> Or_error.error_s [%message "no such follow" (id : string)]
  | Some { state = Stopped; _ } ->
    Or_error.error_s [%message "follow is stopped; follow the leader again" (id : string)]
  | Some r ->
    let record =
      { r with
        scale = Option.value scale ~default:r.scale
      ; caps = Option.value caps ~default:r.caps
      ; state = Option.value state ~default:r.state
      ; updated_ms = now_ms
      }
    in
    Or_error.map (save t record) ~f:(fun () -> record)
;;
