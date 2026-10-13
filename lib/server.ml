open! Core
open! Async
open Hl_protocol
open Ppx_yojson_conv_lib.Yojson_conv.Primitives
module Agent_keys = Hl_copy_keystore.Agent_keys

module Config = struct
  type t =
    { exchange_url : Uri.t
    ; leaderboard_url : Uri.t option
    ; engine_url : Uri.t option
    ; state_dir : string
    ; config_dir : string
    ; public_url : Uri.t
    ; allowed_origins : string list
    ; builder : Agents.Builder.t option
    ; session_ttl : Time_ns.Span.t
    ; requests_per_minute : int
    ; auth_requests_per_minute : int
    ; ws_status_interval : Time_ns.Span.t
    }

  let sexp_of_t t =
    let uri u = Sexp.Atom (Uri.to_string u) in
    [%sexp
      { exchange_url = (uri t.exchange_url : Sexp.t)
      ; leaderboard_url = (Option.map t.leaderboard_url ~f:uri : Sexp.t option)
      ; engine_url = (Option.map t.engine_url ~f:uri : Sexp.t option)
      ; state_dir : string = t.state_dir
      ; config_dir : string = t.config_dir
      ; public_url = (uri t.public_url : Sexp.t)
      ; allowed_origins : string list = t.allowed_origins
      ; builder : Agents.Builder.t option = t.builder
      ; session_ttl : Time_ns.Span.t = t.session_ttl
      ; requests_per_minute : int = t.requests_per_minute
      ; auth_requests_per_minute : int = t.auth_requests_per_minute
      ; ws_status_interval : Time_ns.Span.t = t.ws_status_interval
      }]
  ;;

  let default =
    { exchange_url = Uri.of_string "http://localhost:3000"
    ; leaderboard_url = None
    ; engine_url = None
    ; state_dir = "state"
    ; config_dir = "state/configs"
    ; public_url = Uri.of_string "http://localhost:8080"
    ; allowed_origins = [ "http://localhost:8000" ]
    ; builder = None
    ; session_ttl = Time_ns.Span.of_hr 24.
    ; requests_per_minute = 600
    ; auth_requests_per_minute = 30
    ; ws_status_interval = Time_ns.Span.of_sec 15.
    }
  ;;
end

(* Lenient request bodies: the brief's shapes ([{signature}] alone, no nonce) next to the
   Api_types ones. *)
module Bodies = struct
  type verify =
    { address : Api_types.Address.t
    ; nonce : string option [@default None]
    ; signature : string
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  type agent_approved =
    { approve_agent : Api_types.Approve_agent.t option [@default None]
    ; signature : string
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  type builder_fee =
    { approve_builder_fee : Api_types.Approve_builder_fee.t option [@default None]
    ; signature : string
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  type follow_update =
    { state : Api_types.Follow_state.t option [@default None]
    ; scale : Api_types.Scale_mode.t option [@default None]
    ; caps : Api_types.Caps.t option [@default None]
    }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]
end

module Ws_client = struct
  type t =
    { address : Address.t
    ; send : string Pipe.Writer.t
    }
end

type t =
  { config : Config.t
  ; info_config : Hl_client.Config.t
  ; session : Session.t
  ; challenges : Challenge.t
  ; agents : Agents.t
  ; follows : Follows.t
  ; leaders : Leaders.t option
  ; metrics : Metrics.t
  ; limiter : Rate_limiter.t
  ; auth_limiter : Rate_limiter.t
  ; ws_clients : Ws_client.t Int.Table.t
  ; mutable next_ws_id : int
  ; mutable fill_feed : Hl_client.User_feed.t Or_error.t Deferred.t option
  }

let config t = t.config
let metrics t = t.metrics
let agents t = t.agents
let follows t = t.follows

let create (config : Config.t) ~master_key =
  let open Or_error.Let_syntax in
  let%map venue = Venue.create ~base_url:config.exchange_url () in
  let keys = Agent_keys.create ~dir:(config.state_dir ^/ "agents") master_key in
  let host = Option.value (Uri.host config.public_url) ~default:"localhost" in
  let domain =
    match Uri.port config.public_url with
    | Some port -> sprintf "%s:%d" host port
    | None -> host
  in
  let t =
    { config
    ; info_config = Venue.config venue
    ; session =
        Session.create
          ~ttl:config.session_ttl
          ~key:(Hl_copy_keystore.Sealed.Master_key.derive master_key ~label:"session")
          ()
    ; challenges =
        Challenge.create
          ~domain
          ~uri:(Uri.to_string config.public_url)
          ~chain_id:(Int.of_string (Venue.signature_chain_id venue))
          ()
    ; agents = Agents.create ?builder:config.builder ~keys venue
    ; follows =
        Follows.create
          ~config_dir:config.config_dir
          ~state_dir:(config.state_dir ^/ "follows")
    ; leaders =
        Option.map config.leaderboard_url ~f:(fun base_url -> Leaders.create ~base_url ())
    ; metrics = Metrics.create ()
    ; limiter =
        Rate_limiter.create
          ~per_minute:config.requests_per_minute
          ~burst:(Int.max 1 (config.requests_per_minute / 4))
    ; auth_limiter =
        Rate_limiter.create
          ~per_minute:config.auth_requests_per_minute
          ~burst:(Int.max 1 (config.auth_requests_per_minute / 3))
    ; ws_clients = Int.Table.create ()
    ; next_ws_id = 0
    ; fill_feed = None
    }
  in
  Metrics.gauge t.metrics "challenges_outstanding" (fun () ->
    Float.of_int (Challenge.outstanding t.challenges));
  Metrics.gauge t.metrics "ws_clients" (fun () ->
    Float.of_int (Hashtbl.length t.ws_clients));
  t
;;

(* Replies *)

module Reply = struct
  type t =
    { status : Cohttp.Code.status_code
    ; body : string
    ; content_type : string
    }

  let json ?(status = `OK) json =
    { status; body = Yojson.Safe.to_string json; content_type = "application/json" }
  ;;

  let error status message =
    json ~status (Api_types.Api_error.yojson_of_t { error = message })
  ;;

  let text body = { status = `OK; body; content_type = "text/plain; version=0.0.4" }
end

exception Reply_error of Cohttp.Code.status_code * string

let fail status message = raise (Reply_error (status, message))

let ok_or ?(status = `Bad_request) = function
  | Ok x -> x
  | Error e -> fail status (Error.to_string_hum e)
;;

let max_body = 65_536

let read_json body req =
  let too_large =
    match Cohttp.Header.get (Cohttp.Request.headers req) "content-length" with
    | Some n ->
      Option.value_map (Int.of_string_opt n) ~default:false ~f:(fun n -> n > max_body)
    | None -> false
  in
  if too_large then fail `Request_entity_too_large "request body over 64 KiB";
  let%map s = Cohttp_async.Body.to_string body in
  if String.length s > max_body
  then fail `Request_entity_too_large "request body over 64 KiB";
  if String.is_empty (String.strip s)
  then `Assoc []
  else (
    try Yojson.Safe.from_string s with
    | Yojson.Json_error _ -> fail `Bad_request "request body is not JSON")
;;

(* ppx_yojson_conv messages embed the source path of the type; keep only what names the
   offending field. *)
let decode of_yojson json =
  try of_yojson json with
  | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (exn, _) ->
    let msg =
      match exn with
      | Failure msg -> msg
      | exn -> Exn.to_string exn
    in
    let msg =
      match String.rsplit2 msg ~on:':' with
      | Some (_, detail) -> String.strip detail
      | None -> msg
    in
    fail `Bad_request ("invalid request body: " ^ msg)
  | _ -> fail `Bad_request "invalid request body"
;;

let ms_now () = Time_ns.to_int_ns_since_epoch (Time_ns.now ()) / 1_000_000

(* Views *)

let agent_status t ~owner : Api_types.Agent_status.t option =
  let entries = Agent_keys.entries (Agents.keys t.agents) ~owner |> Result.ok in
  let entries = Option.value entries ~default:[] in
  let pick =
    match List.find entries ~f:(fun e -> Agent_keys.Status.equal e.status Active) with
    | Some e -> Some e
    | None -> List.find entries ~f:(fun e -> Agent_keys.Status.equal e.status Pending)
  in
  Option.map pick ~f:(fun (e : Agent_keys.Entry.t) ->
    { Api_types.Agent_status.agent_address = Approvals.address_to_api e.agent_address
    ; agent_name = e.agent_name
    ; approved = Agent_keys.Status.equal e.status Active
    ; valid_until = Option.map e.valid_until_ms ~f:Float.of_int
    ; builder_fee =
        (match t.config.builder with
         | Some b when Agents.builder_fee_approved t.agents ~owner ->
           Some (Builder_fee.percent_of_tenths_bp b.max_fee_tenths_bp)
         | Some _ | None -> None)
    })
;;

let follow_view (engine : Engine_status.t) (r : Follows.Record.t) : Api_types.Follow.t =
  let status = Engine_status.find engine ~follower:r.follower ~leader:r.leader in
  { id = r.id
  ; leader = Approvals.address_to_api r.leader
  ; scale = r.scale
  ; caps = r.caps
  ; state = r.state
  ; created_at = Float.of_int r.created_ms
  ; pnl = Option.value_map status ~default:0. ~f:(fun s -> s.pnl)
  ; positions = Option.value_map status ~default:[] ~f:(fun s -> s.positions)
  }
;;

let engine_status t = Engine_status.fetch t.config.engine_url

let me t ~address =
  let%bind engine = engine_status t in
  let%map state = Hl_client.Info.clearinghouse_state ~user:address t.info_config in
  let account_value =
    match state with
    | Ok s -> Float.of_string (Usd.to_string s.margin_summary.account_value)
    | Error _ -> 0.
  in
  let follows =
    List.map (Follows.list t.follows ~follower:address) ~f:(follow_view engine)
  in
  { Api_types.Me.address = Approvals.address_to_api address
  ; account_value
  ; total_pnl = List.sum (module Float) follows ~f:(fun f -> f.pnl)
  ; agent = agent_status t ~owner:address
  ; follows
  }
;;

(* Websocket pushes *)

let push t ~address message =
  let text = Ws_push.to_string message in
  Hashtbl.iter t.ws_clients ~f:(fun (c : Ws_client.t) ->
    if Address.equal c.address address && not (Pipe.is_closed c.send)
    then Pipe.write_without_pushback c.send text)
;;

let follow_changed t (r : Follows.Record.t) =
  if Hashtbl.exists t.ws_clients ~f:(fun c -> Address.equal c.address r.follower)
  then
    don't_wait_for
      (let%map engine = engine_status t in
       push t ~address:r.follower (Follow (follow_view engine r)))
;;

let fill_feed t =
  match t.fill_feed with
  | Some feed -> feed
  | None ->
    let feed = Hl_client.User_feed.create t.info_config in
    t.fill_feed <- Some feed;
    feed
;;

let stream_fills t (client : Ws_client.t) =
  match%bind fill_feed t with
  | Error e ->
    Log.Global.info_s [%message "fill feed unavailable" (e : Error.t)];
    return ()
  | Ok feed ->
    (match%bind Hl_client.User_feed.subscribe feed ~address:client.address with
     | Error e ->
       Log.Global.info_s [%message "fill subscription refused" (e : Error.t)];
       return ()
     | Ok updates ->
       don't_wait_for
         (let%map () = Pipe.closed client.send in
          Pipe.close_read updates);
       Pipe.iter_without_pushback updates ~f:(function
         | Fills { fills; is_snapshot = false; _ } ->
           List.iter fills ~f:(fun f ->
             if not (Pipe.is_closed client.send)
             then
               Pipe.write_without_pushback
                 client.send
                 (Ws_push.to_string (Fill (Leaders.fill_to_api f))))
         | Fills { is_snapshot = true; _ } | Position _ | Resync _ -> ()))
;;

let header req name = Cohttp.Header.get (Cohttp.Request.headers req) name

let header_has req name value =
  match header req name with
  | Some v ->
    String.split v ~on:','
    |> List.exists ~f:(fun v -> String.Caseless.equal (String.strip v) value)
  | None -> false
;;

let ws_upgrade t req ~address =
  match header req "sec-websocket-key" with
  | None -> fail `Bad_request "missing Sec-WebSocket-Key"
  | Some key ->
    let headers =
      Http.Header.of_list
        [ "upgrade", "websocket"
        ; "connection", "Upgrade"
        ; ( "sec-websocket-accept"
          , Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key )
        ]
    in
    (* [Http.Response.make], unlike [Cohttp.Response.make], does not add
       [transfer-encoding: chunked], which is invalid on a 101. *)
    let response = Http.Response.make ~status:`Switching_protocols ~headers () in
    ( response
    , fun reader writer ->
        let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
        let incoming, outgoing = Websocket.pipes ws in
        let id = t.next_ws_id in
        t.next_ws_id <- id + 1;
        let client = { Ws_client.address; send = outgoing } in
        Hashtbl.set t.ws_clients ~key:id ~data:client;
        let send_me () =
          let%map me = me t ~address in
          if not (Pipe.is_closed outgoing)
          then Pipe.write_without_pushback outgoing (Ws_push.to_string (Me me))
        in
        let%bind () = send_me () in
        don't_wait_for (stream_fills t client);
        Clock_ns.every'
          ~stop:(Pipe.closed outgoing)
          ~continue_on_error:false
          t.config.ws_status_interval
          send_me;
        (* Nothing is expected from the client; reading keeps the connection's control
           frames flowing and notices the close. *)
        let%bind () = Pipe.drain incoming in
        Pipe.close outgoing;
        Hashtbl.remove t.ws_clients id;
        return () )
;;

(* Routing *)

let authenticate t req =
  match Option.bind (header req "authorization") ~f:Session.of_authorization_header with
  | None -> fail `Unauthorized "missing session token"
  | Some token ->
    (match Session.verify t.session ~now:(Time_ns.now ()) token with
     | Ok claims -> claims.address
     | Error e -> fail `Unauthorized (Error.to_string_hum e))
;;

let parse_address s =
  match Api_types.Address.of_string_opt s with
  | Some a -> Approvals.address_of_api a
  | None -> fail `Bad_request "not an address (0x followed by 40 hex digits)"
;;

let follower_count t leader =
  List.count (Follows.all t.follows) ~f:(fun r ->
    Address.equal r.leader leader
    &&
    match r.state with
    | Running | Paused -> true
    | Stopped -> false)
;;

let find_follow t ~follower id =
  match Follows.find t.follows ~follower id with
  | Some r -> r
  | None -> fail `Not_found "no such follow"
;;

let follow_reply ?(status = `OK) t r =
  follow_changed t r;
  let%map engine = engine_status t in
  Reply.json ~status (Api_types.Follow.yojson_of_t (follow_view engine r))
;;

let update_follow t ~follower id ?scale ?caps ?state () =
  let r = find_follow t ~follower id in
  match
    Follows.update t.follows ~follower r.id ?scale ?caps ?state ~now_ms:(ms_now ()) ()
  with
  | Ok r -> follow_reply t r
  | Error e -> fail `Conflict (Error.to_string_hum e)
;;

let offer_json (offer : Api_types.Agent_offer.t) =
  match Api_types.Agent_offer.yojson_of_t offer with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ ( "typed_data"
           , `Assoc
               (("approve_agent", Api_types.Approve_agent.typed_data offer.approve_agent)
                :: Option.value_map offer.approve_builder_fee ~default:[] ~f:(fun f ->
                  [ "approve_builder_fee", Api_types.Approve_builder_fee.typed_data f ]))
           )
         ])
  | json -> json
;;

let route t ~body req ~meth ~path =
  let auth () = authenticate t req in
  let agent_status_reply owner =
    match agent_status t ~owner with
    | Some s -> Reply.json (Api_types.Agent_status.yojson_of_t s)
    | None -> Reply.error `Not_found "no agent"
  in
  match meth, path with
  | `GET, [ "healthz" ] ->
    "/healthz", fun () -> return (Reply.json (`Assoc [ "status", `String "ok" ]))
  | `GET, [ "metrics" ] ->
    "/metrics", fun () -> return (Reply.text (Metrics.render t.metrics))
  | `POST, [ "auth"; "challenge" ] ->
    ( "/auth/challenge"
    , fun () ->
        let%map json = read_json body req in
        let r = decode Api_types.Auth.Challenge_request.t_of_yojson json in
        let challenge =
          Challenge.issue
            t.challenges
            (Approvals.address_of_api r.address)
            ~now:(Time_ns.now ())
        in
        Reply.json (Api_types.Auth.Challenge.yojson_of_t challenge) )
  | `POST, [ "auth"; ("verify" | "login") ] ->
    ( "/auth/verify"
    , fun () ->
        let%map json = read_json body req in
        let r = decode Bodies.verify_of_yojson json in
        let address = Approvals.address_of_api r.address in
        let now = Time_ns.now () in
        let message =
          Challenge.consume t.challenges address ~nonce:r.nonce ~now
          |> ok_or ~status:`Unauthorized
        in
        let signer =
          Wallet_signature.recover_personal ~message r.signature
          |> ok_or ~status:`Unauthorized
        in
        if not (Address.equal signer address)
        then fail `Unauthorized "signature is not from this address";
        let token, claims = Session.issue t.session address ~now in
        Metrics.incr t.metrics "logins";
        Reply.json
          (Api_types.Auth.Session.yojson_of_t
             { token; address = r.address; expires_at = Float.of_int claims.expires_ms })
    )
  | `POST, ([ "agent"; "new" ] | [ "agent" ]) ->
    ( "/agent/new"
    , fun () ->
        let owner = auth () in
        let offer =
          Agents.offer t.agents ~owner ~now:(Time_ns.now ())
          |> ok_or ~status:`Internal_server_error
        in
        Metrics.incr t.metrics "agent_offers";
        return (Reply.json (offer_json offer)) )
  | `POST, [ "agent"; "approved" ] ->
    ( "/agent/approved"
    , fun () ->
        let owner = auth () in
        let%bind json = read_json body req in
        let r = decode Bodies.agent_approved_of_yojson json in
        let%map result =
          Agents.approve_agent
            t.agents
            ~owner
            ?signed:r.approve_agent
            ~signature:r.signature
            ()
        in
        let (_ : Agent_keys.Entry.t) = ok_or ~status:`Bad_gateway result in
        Metrics.incr t.metrics "agents_approved";
        agent_status_reply owner )
  | `POST, [ "agent"; "revoke" ] ->
    ( "/agent/revoke"
    , fun () ->
        let owner = auth () in
        let (_ : Agent_keys.Entry.t) =
          Agents.revoke t.agents ~owner |> ok_or ~status:`Conflict
        in
        (* Without an agent the engine cannot trade; pause the user's running follows so
           the dashboard says so. *)
        List.iter (Follows.list t.follows ~follower:owner) ~f:(fun r ->
          match r.state with
          | Running ->
            (match
               Follows.update
                 t.follows
                 ~follower:owner
                 r.id
                 ~state:Paused
                 ~now_ms:(ms_now ())
                 ()
             with
             | Ok r -> follow_changed t r
             | Error _ -> ())
          | Paused | Stopped -> ());
        return
          (match agent_status t ~owner with
           | Some s -> Reply.json (Api_types.Agent_status.yojson_of_t s)
           | None -> Reply.json `Null) )
  | `POST, [ "builder-fee" ] ->
    ( "/builder-fee"
    , fun () ->
        let owner = auth () in
        let%bind json = read_json body req in
        let r = decode Bodies.builder_fee_of_yojson json in
        let%map result =
          Agents.approve_builder_fee
            t.agents
            ~owner
            ?signed:r.approve_builder_fee
            ~signature:r.signature
            ()
        in
        ok_or ~status:`Bad_gateway result;
        Metrics.incr t.metrics "builder_fees_approved";
        agent_status_reply owner )
  | `GET, [ "follows" ] ->
    ( "/follows"
    , fun () ->
        let follower = auth () in
        let%map engine = engine_status t in
        Reply.json
          (`List
            (List.map (Follows.list t.follows ~follower) ~f:(fun r ->
               Api_types.Follow.yojson_of_t (follow_view engine r)))) )
  | `POST, [ "follows" ] ->
    ( "/follows"
    , fun () ->
        let follower = auth () in
        let%bind json = read_json body req in
        let r = decode Api_types.Follow_request.t_of_yojson json in
        if Option.is_none (Agents.active t.agents ~owner:follower)
        then fail `Conflict "approve an agent before following";
        let leader = Approvals.address_of_api r.leader in
        let record =
          Follows.start
            t.follows
            ~follower
            ~leader
            ~scale:r.scale
            ~caps:r.caps
            ~now_ms:(ms_now ())
          |> ok_or ~status:`Conflict
        in
        Metrics.incr t.metrics "follows_started";
        follow_reply ~status:`Created t record )
  | `GET, [ "follows"; id ] ->
    ( "/follows/:id"
    , fun () ->
        let follower = auth () in
        let r = find_follow t ~follower id in
        let%map engine = engine_status t in
        Reply.json (Api_types.Follow.yojson_of_t (follow_view engine r)) )
  | `PATCH, [ "follows"; id ] ->
    ( "/follows/:id"
    , fun () ->
        let follower = auth () in
        let%bind json = read_json body req in
        let u = decode Bodies.follow_update_of_yojson json in
        (match u.state with
         | Some Stopped -> fail `Bad_request "use DELETE to stop a follow"
         | Some (Running | Paused) | None -> ());
        update_follow t ~follower id ?scale:u.scale ?caps:u.caps ?state:u.state () )
  | `DELETE, [ "follows"; id ] ->
    ( "/follows/:id"
    , fun () ->
        let follower = auth () in
        update_follow t ~follower id ~state:Stopped () )
  | `POST, [ "follows"; id; (("pause" | "resume" | "stop") as command) ] ->
    ( "/follows/:id/:command"
    , fun () ->
        let follower = auth () in
        let state : Api_types.Follow_state.t =
          match command with
          | "pause" -> Paused
          | "resume" -> Running
          | _ -> Stopped
        in
        update_follow t ~follower id ~state () )
  | `GET, [ "leaders" ] ->
    ( "/leaders"
    , fun () ->
        (match t.leaders with
         | None -> fail `Service_unavailable "no leaderboard configured"
         | Some leaders ->
           let%map r = Leaders.leaders leaders ~followers:(follower_count t) in
           Reply.json
             (Api_types.Leaders_response.yojson_of_t (ok_or ~status:`Bad_gateway r))) )
  | `GET, [ "leaders"; address ] ->
    ( "/leaders/:address"
    , fun () ->
        let address = parse_address address in
        (match t.leaders with
         | None -> fail `Service_unavailable "no leaderboard configured"
         | Some leaders ->
           let%map r = Leaders.leader leaders ~followers:(follower_count t) address in
           (match ok_or ~status:`Bad_gateway r with
            | Some detail -> Reply.json (Api_types.Leader_detail.yojson_of_t detail)
            | None -> Reply.error `Not_found "unknown leader")) )
  | `GET, [ "me" ] ->
    ( "/me"
    , fun () ->
        let address = auth () in
        let%map me = me t ~address in
        Reply.json (Api_types.Me.yojson_of_t me) )
  | _, _ -> "unknown", fun () -> fail `Not_found "no such route"
;;

let cors_headers t req =
  let origin = header req "origin" in
  let allow =
    match origin with
    | None -> None
    | Some origin ->
      if List.mem t.config.allowed_origins "*" ~equal:String.equal
      then Some "*"
      else if List.mem t.config.allowed_origins origin ~equal:String.equal
      then Some origin
      else None
  in
  match allow with
  | None -> []
  | Some allow ->
    [ "access-control-allow-origin", allow
    ; "vary", "Origin"
    ; "access-control-allow-methods", "GET, POST, PATCH, DELETE, OPTIONS"
    ; "access-control-allow-headers", "authorization, content-type"
    ; "access-control-max-age", "600"
    ]
;;

let client_ip addr =
  match addr with
  | `Inet (inet, _) -> Unix.Inet_addr.to_string inet
  | `Unix path -> path
;;

let handler t ~body addr req =
  let started = Time_ns.now () in
  let meth = Cohttp.Request.meth req in
  let uri = Cohttp.Request.uri req in
  let path =
    String.split (Uri.path uri) ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)
  in
  let ip = client_ip addr in
  let cors = cors_headers t req in
  let respond route (reply : Reply.t) =
    let status = Cohttp.Code.code_of_status reply.status in
    let duration = Time_ns.diff (Time_ns.now ()) started in
    Metrics.request
      t.metrics
      ~route
      ~meth:(Cohttp.Code.string_of_method meth)
      ~status
      ~duration;
    Log.Global.info_s
      [%message
        "request"
          ~method_:(Cohttp.Code.string_of_method meth)
          (route : string)
          (status : int)
          ~ms:(Time_ns.Span.to_ms duration : float)
          (ip : string)];
    let headers = Cohttp.Header.of_list (("content-type", reply.content_type) :: cors) in
    let%map response =
      Cohttp_async.Server.respond_string ~headers ~status:reply.status reply.body
    in
    `Response response
  in
  let limited limiter = not (Rate_limiter.allow limiter ~key:ip ~now:started) in
  match meth, path with
  | `OPTIONS, _ ->
    let%map response =
      Cohttp_async.Server.respond_string
        ~headers:(Cohttp.Header.of_list cors)
        ~status:`No_content
        ""
    in
    `Response response
  | `GET, [ "ws" ] when header_has req "upgrade" "websocket" ->
    if limited t.limiter
    then respond "/ws" (Reply.error `Too_many_requests "rate limited")
    else (
      let token = Uri.get_query_param uri "token" in
      match Option.map token ~f:(Session.verify t.session ~now:started) with
      | None -> respond "/ws" (Reply.error `Unauthorized "missing session token")
      | Some (Error e) ->
        respond "/ws" (Reply.error `Unauthorized (Error.to_string_hum e))
      | Some (Ok claims) ->
        (match ws_upgrade t req ~address:claims.address with
         | exception Reply_error (status, message) ->
           respond "/ws" (Reply.error status message)
         | response, handle ->
           Metrics.request
             t.metrics
             ~route:"/ws"
             ~meth:"GET"
             ~status:101
             ~duration:(Time_ns.diff (Time_ns.now ()) started);
           return (`Expert (response, handle))))
  | _ ->
    let route_name, run = route t ~body req ~meth ~path in
    let is_auth =
      match path with
      | "auth" :: _ -> true
      | _ -> false
    in
    let is_health =
      match path with
      | [ "healthz" ] -> true
      | _ -> false
    in
    if (not is_health) && limited t.limiter
    then respond route_name (Reply.error `Too_many_requests "rate limited")
    else if is_auth && limited t.auth_limiter
    then respond route_name (Reply.error `Too_many_requests "rate limited")
    else (
      let%bind reply =
        match%map
          Monitor.try_with ~extract_exn:true ~rest:`Log (fun () -> Deferred.unit >>= run)
        with
        | Ok reply -> reply
        | Error (Reply_error (status, message)) -> Reply.error status message
        | Error exn ->
          Log.Global.error_s [%message "handler failed" (exn : exn)];
          Reply.error `Internal_server_error "internal error"
      in
      respond route_name reply)
;;

let start t ~port =
  Cohttp_async.Server.create_expert
    ~on_handler_error:
      (`Call (fun _ exn -> Log.Global.error_s [%message "handler error" (exn : exn)]))
    (Tcp.Where_to_listen.of_port port)
    (fun ~body addr req -> handler t ~body addr req)
;;

let close t =
  Hashtbl.iter t.ws_clients ~f:(fun c -> Pipe.close c.send);
  Hashtbl.clear t.ws_clients;
  match t.fill_feed with
  | None -> return ()
  | Some feed ->
    t.fill_feed <- None;
    (match%bind feed with
     | Ok feed -> Hl_client.User_feed.close feed
     | Error _ -> return ())
;;
