open! Core
open! Async
open Hl_copy_api

let uri = Command.Arg_type.create Uri.of_string

let address =
  Command.Arg_type.create (fun s ->
    match Api_types.Address.of_string_opt s with
    | Some a -> Approvals.address_of_api a
    | None -> failwithf "not an address: %s" s ())
;;

let command =
  Command.async_or_error
    ~summary:"HTTP API of the copy-trading platform (hl-sim or testnet only)"
    ~readme:(fun () ->
      "The master key that seals agent keys is read from HL_COPY_MASTER_KEY (64 hex \
       digits; e.g. openssl rand -hex 32). Losing it makes every stored agent key \
       unusable; users then approve a new agent. Mainnet exchange URLs are refused.\n\n\
       Follows, sealed agent keys and builder fee approvals live in PostgreSQL \
       (-database-url, DATABASE_URL or PG*; TLS unless sslmode=disable); pending \
       migrations are applied at startup. The engine's inputs (key files under \
       -state-dir, follower configs under -config-dir) are written from the database.")
    (let%map_open.Command port =
       flag "-port" (optional_with_default 8080 int) ~doc:"PORT listen port (8080)"
     and exchange_url =
       flag
         "-exchange-url"
         (optional_with_default Server.Config.default.exchange_url uri)
         ~doc:"URL hl-sim or testnet API root (http://localhost:3000)"
     and leaderboard_url =
       flag "-leaderboard-url" (optional uri) ~doc:"URL hl-leaderboard serve"
     and engine_url = flag "-engine-url" (optional uri) ~doc:"URL hl-copy-engine"
     and state_dir =
       flag
         "-state-dir"
         (optional_with_default Server.Config.default.state_dir string)
         ~doc:"DIR agent key files for the engine, written from the store (./state)"
     and config_dir =
       flag
         "-config-dir"
         (optional_with_default Server.Config.default.config_dir string)
         ~doc:"DIR follower configs the engine watches (./state/configs)"
     and public_url =
       flag
         "-public-url"
         (optional_with_default Server.Config.default.public_url uri)
         ~doc:"URL this API as browsers reach it (http://localhost:8080)"
     and origins =
       flag
         "-allow-origin"
         (listed string)
         ~doc:
           "ORIGIN allow CORS from ORIGIN (repeatable; * for any; default the web dev \
            server)"
     and builder = flag "-builder" (optional address) ~doc:"ADDRESS builder fee recipient"
     and builder_fee =
       flag
         "-builder-fee"
         (optional_with_default 10 int)
         ~doc:"N builder fee in tenths of a basis point, at most 100 (10 = 0.01%)"
     and session_hours =
       flag "-session-hours" (optional_with_default 24. float) ~doc:"H session lifetime"
     and database_url =
       flag
         "-database-url"
         (optional string)
         ~doc:
           "URL PostgreSQL, e.g. postgres://hl_copy@localhost/hl_copy?sslmode=disable \
            (default DATABASE_URL, else the PG* variables)"
     and memory_store =
       flag
         "-memory-store"
         no_arg
         ~doc:" keep follows and agents in memory only: everything is lost on restart"
     and rpm =
       flag
         "-requests-per-minute"
         (optional_with_default Server.Config.default.requests_per_minute int)
         ~doc:"N per client IP"
     and auth_rpm =
       flag
         "-auth-requests-per-minute"
         (optional_with_default Server.Config.default.auth_requests_per_minute int)
         ~doc:"N per client IP on /auth"
     in
     fun () ->
       let open Deferred.Or_error.Let_syntax in
       Log.Global.set_output [ Log.Output.stderr () ];
       let%bind master_key =
         Deferred.return (Hl_copy_core.Key_store.Master_key.of_env ())
       in
       let%bind builder =
         match builder with
         | None -> return None
         | Some _ when builder_fee < 0 || builder_fee > 100 ->
           Deferred.Or_error.error_string "-builder-fee must be between 0 and 100"
         | Some address ->
           return (Some { Agents.Builder.address; max_fee_tenths_bp = builder_fee })
       in
       let config =
         { Server.Config.exchange_url
         ; leaderboard_url
         ; engine_url
         ; state_dir
         ; config_dir
         ; public_url
         ; allowed_origins =
             (if List.is_empty origins
              then Server.Config.default.allowed_origins
              else origins)
         ; builder
         ; session_ttl = Time_ns.Span.of_hr session_hours
         ; requests_per_minute = rpm
         ; auth_requests_per_minute = auth_rpm
         ; ws_status_interval = Server.Config.default.ws_status_interval
         }
       in
       let%bind store =
         if memory_store
         then return (Store_memory.store (Store_memory.create ()))
         else (
           let%map pg = Store_pg.connect ?database_url () in
           let applied = Store_pg.applied_migrations pg in
           if not (List.is_empty applied)
           then Log.Global.info_s [%message "applied migrations" (applied : int list)];
           Store_pg.store pg)
       in
       Log.Global.info_s [%message "store" ~kind:(Store.kind store : string)];
       let%bind api = Server.create config ~master_key ~store in
       let%bind.Deferred server = Server.start api ~port in
       Log.Global.info_s
         [%message
           "listening"
             ~port:(Cohttp_async.Server.listening_on server : int)
             (config : Server.Config.t)];
       Deferred.ok (Cohttp_async.Server.close_finished server))
;;

let () = Command_unix.run command
