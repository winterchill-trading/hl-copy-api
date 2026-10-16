open! Core
open! Async
open Hl_protocol
open Pg_async
module Entry = Hl_copy_core.Key_store.Entry

type t =
  { pool : Pool.t
  ; description : string
  ; applied_migrations : int list
  }

let kind t = t.description

let or_error ~label d =
  d >>| fun r -> Pg_error.to_or_error r |> Or_error.tag ~tag:("store: " ^ label)
;;

let migrations =
  List.map Migrations_sql.all ~f:(fun (version, name, sql) ->
    { Migrate.Migration.version; name; sql })
;;

let migrate config =
  let open Deferred.Or_error.Let_syntax in
  let%bind conn = or_error ~label:"connect" (Connection.connect config) in
  let%bind.Deferred applied = Migrate.apply conn migrations in
  let%bind.Deferred () = Connection.close conn in
  Deferred.return (Result.map_error applied ~f:Migrate.Error.to_error)
;;

let connect ?database_url ?(max_connections = 4) () =
  let open Deferred.Or_error.Let_syntax in
  let%bind config =
    Deferred.return
      (match database_url with
       | Some url -> Config.of_url url
       | None -> Config.of_env ())
  in
  let config = { config with application_name = "hl-copy-api" } in
  let%map applied_migrations = migrate config in
  { pool = Pool.create ~max_size:max_connections config
  ; description = "postgres " ^ Config.to_string_hum config
  ; applied_migrations
  }
;;

let applied_migrations t = t.applied_migrations
let close t = Pool.close t.pool

let address =
  Type.map
    Type.string
    ~name:"address"
    ~f:(fun s -> Ok (Address.of_string s))
    ~f_inv:Address.to_string
;;

let follow_state =
  Type.map
    Type.string
    ~name:"follow_state"
    ~f:(function
      | "running" -> Ok Api_types.Follow_state.Running
      | "paused" -> Ok Paused
      | "stopped" -> Ok Stopped
      | s -> Error ("unknown follow state " ^ s))
    ~f_inv:(function
      | Api_types.Follow_state.Running -> "running"
      | Paused -> "paused"
      | Stopped -> "stopped")
;;

(* Follows *)

let follow_columns =
  "id, follower, leader, scale_mode, scale_value, max_leverage, max_notional_per_symbol, \
   max_daily_loss, allowlist, min_order_notional, state, created_ms, updated_ms, algo"
;;

(* The scale is two columns (mode and value, constrained together in the migration), so a
   row decodes to a result and a bad combination is an error, not an exception. *)
let follow_row =
  let open Row.Let_syntax in
  let%map_open id = column "id" string
  and follower = column "follower" address
  and leader = column "leader" address
  and scale_mode = column "scale_mode" string
  and scale_value = column "scale_value" (nullable float)
  and max_leverage = column "max_leverage" float
  and max_notional_per_symbol = column "max_notional_per_symbol" float
  and max_daily_loss = column "max_daily_loss" float
  and allowlist = column "allowlist" (array string)
  and min_order_notional = column "min_order_notional" float
  and state = column "state" follow_state
  and created_ms = column "created_ms" int
  and updated_ms = column "updated_ms" int
  and algo = column "algo" (nullable string) in
  let scale : (Api_types.Scale_mode.t, Error.t) Result.t =
    match scale_mode, scale_value with
    | "equity_ratio", None -> Ok Equity_ratio
    | "multiplier", Some k -> Ok (Multiplier k)
    | "fixed_notional", Some n -> Ok (Fixed_notional n)
    | _ ->
      Or_error.error_s
        [%message "bad scale in follows row" id scale_mode (scale_value : float option)]
  in
  Result.map scale ~f:(fun scale ->
    { Follow_record.id
    ; follower
    ; leader
    ; scale
    ; caps =
        { max_leverage
        ; max_notional_per_symbol
        ; max_daily_loss
        ; allowlist
        ; min_order_notional
        }
    ; state
    ; created_ms
    ; updated_ms
    ; algo
    })
;;

let follow_params (r : Follow_record.t) =
  let mode, value =
    match r.scale with
    | Equity_ratio -> "equity_ratio", None
    | Multiplier k -> "multiplier", Some k
    | Fixed_notional n -> "fixed_notional", Some n
  in
  [ Param.string r.id
  ; Param.create address r.follower
  ; Param.create address r.leader
  ; Param.string mode
  ; Param.option Type.float value
  ; Param.float r.caps.max_leverage
  ; Param.float r.caps.max_notional_per_symbol
  ; Param.float r.caps.max_daily_loss
  ; Param.array Type.string r.caps.allowlist
  ; Param.float r.caps.min_order_notional
  ; Param.create follow_state r.state
  ; Param.int r.created_ms
  ; Param.int r.updated_ms
  ; Param.option Type.string r.algo
  ]
;;

let insert_follow =
  sprintf
    "INSERT INTO follows (%s) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, \
     $13, $14)"
    follow_columns
;;

let find_follow t ~id =
  or_error
    ~label:"find_follow"
    (Pool.fetch_opt
       ~label:"find_follow"
       t.pool
       (sprintf "SELECT %s FROM follows WHERE id = $1" follow_columns)
       ~params:[ Param.string id ]
       ~row:follow_row)
  >>| Or_error.bind ~f:(function
    | None -> Ok None
    | Some r -> Or_error.map r ~f:Option.some)
;;

(* [COLLATE "C"] orders ids bytewise, as [String.compare] does in the memory store; the
   database's default collation may not. *)
let follows ?follower t () =
  or_error
    ~label:"follows"
    (Pool.fetch_all
       ~label:"follows"
       t.pool
       (sprintf
          "SELECT %s FROM follows WHERE $1::text IS NULL OR follower = $1 ORDER BY \
           created_ms, id COLLATE \"C\""
          follow_columns)
       ~params:[ Param.option address follower ]
       ~row:follow_row)
  >>| Or_error.bind ~f:Or_error.all
;;

let put_follow t r =
  or_error
    ~label:"put_follow"
    (Pool.execute
       ~label:"put_follow"
       t.pool
       (insert_follow
        ^ " ON CONFLICT (id) DO UPDATE SET follower = EXCLUDED.follower, leader = \
           EXCLUDED.leader, scale_mode = EXCLUDED.scale_mode, scale_value = \
           EXCLUDED.scale_value, max_leverage = EXCLUDED.max_leverage, \
           max_notional_per_symbol = EXCLUDED.max_notional_per_symbol, max_daily_loss = \
           EXCLUDED.max_daily_loss, allowlist = EXCLUDED.allowlist, min_order_notional = \
           EXCLUDED.min_order_notional, state = EXCLUDED.state, created_ms = \
           EXCLUDED.created_ms, updated_ms = EXCLUDED.updated_ms, algo = EXCLUDED.algo")
       ~params:(follow_params r))
  >>| Or_error.ignore_m
;;

let add_follow_if_absent t r =
  or_error
    ~label:"add_follow_if_absent"
    (Pool.execute
       ~label:"add_follow_if_absent"
       t.pool
       (insert_follow ^ " ON CONFLICT (id) DO NOTHING")
       ~params:(follow_params r))
  >>| Or_error.map ~f:(fun n -> n = 1)
;;

(* Agents. The key store keeps ciphertext, nonce and tag as lowercase hex; the table keeps
   the bytes. *)

let agent_columns =
  "account, agent_address, agent_name, created_ns, valid_until_ns, ciphertext, nonce, tag"
;;

let agent_row =
  let open Row.Let_syntax in
  let%map_open account = column "account" address
  and agent_address = column "agent_address" address
  and agent_name = column "agent_name" string
  and created_ns = column "created_ns" int
  and valid_until_ns = column "valid_until_ns" (nullable int)
  and ciphertext = column "ciphertext" bytea
  and nonce = column "nonce" bytea
  and tag = column "tag" bytea in
  ( account
  , { Entry.agent_address
    ; agent_name
    ; created = Time_ns.of_int_ns_since_epoch created_ns
    ; valid_until = Option.map valid_until_ns ~f:Time_ns.of_int_ns_since_epoch
    ; ciphertext = Hex.of_bytes ciphertext
    ; nonce = Hex.of_bytes nonce
    ; tag = Hex.of_bytes tag
    } )
;;

let agent_params ~account (e : Entry.t) =
  let open Or_error.Let_syntax in
  let%bind ciphertext = Hex.to_bytes e.ciphertext
  and nonce = Hex.to_bytes e.nonce
  and tag = Hex.to_bytes e.tag in
  Ok
    [ Param.create address account
    ; Param.create address e.agent_address
    ; Param.string e.agent_name
    ; Param.int (Time_ns.to_int_ns_since_epoch e.created)
    ; Param.option Type.int (Option.map e.valid_until ~f:Time_ns.to_int_ns_since_epoch)
    ; Param.bytea ciphertext
    ; Param.bytea nonce
    ; Param.bytea tag
    ]
;;

let insert_agent =
  sprintf "INSERT INTO agents (%s) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)" agent_columns
;;

let find_agent t ~account =
  or_error
    ~label:"find_agent"
    (Pool.fetch_opt
       ~label:"find_agent"
       t.pool
       (sprintf "SELECT %s FROM agents WHERE account = $1" agent_columns)
       ~params:[ Param.create address account ]
       ~row:agent_row)
  >>| Or_error.map ~f:(Option.map ~f:snd)
;;

let agents t =
  or_error
    ~label:"agents"
    (Pool.fetch_all
       ~label:"agents"
       t.pool
       (sprintf "SELECT %s FROM agents ORDER BY account COLLATE \"C\"" agent_columns)
       ~row:agent_row)
;;

let write_agent t ~label ~account entry ~on_conflict =
  match agent_params ~account entry with
  | Error _ as e -> return (Or_error.tag e ~tag:("store: " ^ label))
  | Ok params ->
    or_error
      ~label
      (Pool.execute ~label t.pool (insert_agent ^ " " ^ on_conflict) ~params)
;;

let put_agent t ~account entry =
  write_agent
    t
    ~label:"put_agent"
    ~account
    entry
    ~on_conflict:
      "ON CONFLICT (account) DO UPDATE SET agent_address = EXCLUDED.agent_address, \
       agent_name = EXCLUDED.agent_name, created_ns = EXCLUDED.created_ns, \
       valid_until_ns = EXCLUDED.valid_until_ns, ciphertext = EXCLUDED.ciphertext, nonce \
       = EXCLUDED.nonce, tag = EXCLUDED.tag, updated_at = now()"
  >>| Or_error.ignore_m
;;

let add_agent_if_absent t ~account entry =
  write_agent
    t
    ~label:"add_agent_if_absent"
    ~account
    entry
    ~on_conflict:"ON CONFLICT (account) DO NOTHING"
  >>| Or_error.map ~f:(fun n -> n = 1)
;;

let delete_agent t ~account =
  or_error
    ~label:"delete_agent"
    (Pool.execute
       ~label:"delete_agent"
       t.pool
       "DELETE FROM agents WHERE account = $1"
       ~params:[ Param.create address account ])
  >>| Or_error.ignore_m
;;

(* Builder fees *)

let builder_fee_approved t ~account ~builder =
  or_error
    ~label:"builder_fee_approved"
    (Pool.fetch_one
       ~label:"builder_fee_approved"
       t.pool
       "SELECT EXISTS (SELECT 1 FROM builder_fee_approvals WHERE account = $1 AND \
        builder = $2) AS approved"
       ~params:[ Param.create address account; Param.create address builder ]
       ~row:(Row.column "approved" Type.bool))
;;

let approve_builder_fee t ~account ~builder ~at =
  or_error
    ~label:"approve_builder_fee"
    (Pool.execute
       ~label:"approve_builder_fee"
       t.pool
       "INSERT INTO builder_fee_approvals (account, builder, approved_at) VALUES ($1, \
        $2, $3) ON CONFLICT (account, builder) DO NOTHING"
       ~params:
         [ Param.create address account; Param.create address builder; Param.time_ns at ])
  >>| Or_error.ignore_m
;;

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
