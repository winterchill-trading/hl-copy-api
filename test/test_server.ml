open! Core
open! Async
open Hl_copy_api
module Address = Hl_protocol.Address
module Signing = Hl_client.Signing
module C = Api_client

let leader = Address.of_string "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf"

let%expect_test "mainnet exchange URL is refused at startup" =
  print_s
    [%sexp
      (Server.create
         { Server.Config.default with
           exchange_url = Uri.of_string "https://api.hyperliquid.xyz"
         }
         ~master_key:Flow.master
       |> Result.is_error
       : bool)];
  [%expect {| true |}];
  return ()
;;

let%expect_test "CORS preflight and headers" =
  Flow.with_api (fun ~sim:_ ~api:_ ~client ~dir:_ ->
    let show headers =
      let%map status, h, _ = C.call_raw client ~headers `OPTIONS "/follows" in
      print_s
        [%sexp
          (status : int)
          , (Cohttp.Header.get h "access-control-allow-origin" : string option)
          , (Cohttp.Header.get h "access-control-allow-headers" : string option)]
    in
    let%bind () = show [ "origin", "http://localhost:8000" ] in
    let%bind () = show [ "origin", "https://evil.example" ] in
    [%expect
      {|
      (204 (http://localhost:8000) ("authorization, content-type"))
      (204 () ())
      |}];
    let%bind status, h, _ =
      C.call_raw client ~headers:[ "origin", "http://localhost:8000" ] `GET "/healthz"
    in
    print_s
      [%sexp
        (status : int)
        , (Cohttp.Header.get h "access-control-allow-origin" : string option)];
    [%expect {| (200 (http://localhost:8000)) |}];
    return ())
;;

let%expect_test "bad bodies, unknown routes, no leaderboard, metrics" =
  Flow.with_api (fun ~sim:_ ~api:_ ~client ~dir:_ ->
    let show (status, json) =
      print_s [%sexp (status : int), (C.str "error" json : string)]
    in
    let%bind r = C.call client `POST "/auth/challenge" ~body:(`Assoc []) in
    show r;
    let%bind r =
      C.call client `POST "/auth/challenge" ~body:(`Assoc [ "address", `String "0x12" ])
    in
    show r;
    let%bind r =
      C.call client `POST "/auth/challenge" ~body:(`String (String.make 70_000 'x'))
    in
    show r;
    let%bind r = C.call client `GET "/nope" in
    show r;
    let%bind r = C.call client `GET "/leaders" in
    show r;
    let%bind r = C.call client `GET "/leaders/0x12" in
    show r;
    let%bind r = C.call client ~token:"x.y.z.w" `GET "/me" in
    show r;
    [%expect
      {|
      (400 "invalid request body: address")
      (400 "invalid request body: expected a 0x-prefixed 40 digit hex address")
      (413 "request body over 64 KiB")
      (404 "no such route")
      (503 "no leaderboard configured")
      (400 "not an address (0x followed by 40 hex digits)")
      (401 "invalid session token")
      |}];
    let%bind _, _, metrics = C.call_raw client `GET "/metrics" in
    String.split_lines metrics
    |> List.filter ~f:(String.is_prefix ~prefix:"hl_copy_api_requests_total")
    |> List.iter ~f:print_endline;
    [%expect
      {|
      hl_copy_api_requests_total{route="/auth/challenge",method="POST",status="400"} 2
      hl_copy_api_requests_total{route="/auth/challenge",method="POST",status="413"} 1
      hl_copy_api_requests_total{route="/leaders",method="GET",status="503"} 1
      hl_copy_api_requests_total{route="/leaders/:address",method="GET",status="400"} 1
      hl_copy_api_requests_total{route="/me",method="GET",status="401"} 1
      hl_copy_api_requests_total{route="unknown",method="GET",status="404"} 1
      |}];
    return ())
;;

let%expect_test "rate limits" =
  Flow.with_api
    ~configure:(fun c -> { c with requests_per_minute = 8; auth_requests_per_minute = 3 })
    (fun ~sim:_ ~api:_ ~client ~dir:_ ->
      let challenge () =
        let%map status, _ =
          C.call
            client
            `POST
            "/auth/challenge"
            ~body:(`Assoc [ "address", `String (Address.to_string leader) ])
        in
        status
      in
      (* Burst 1 on auth (3 per minute / 3), 2 overall (8 / 4). *)
      let%bind a = challenge () in
      let%bind b = challenge () in
      let%bind c, _ = C.call client `GET "/nope" in
      let%bind d, _ = C.call client `GET "/nope" in
      let%bind e, _ = C.call client `GET "/healthz" in
      print_s [%sexp ([ a; b; c; d; e ] : int list)];
      [%expect {| (200 429 429 429 200) |}];
      return ())
;;

let next_message ws =
  match%map
    Clock_ns.with_timeout
      (Time_ns.Span.of_sec 10.)
      (Pipe.read (Venue_net.Ws_client.messages ws))
  with
  | `Result (`Ok text) -> Yojson.Safe.from_string text
  | `Result `Eof -> `String "eof"
  | `Timeout -> `String "timeout"
;;

let%expect_test "websocket: me on connect, follow changes, own fills" =
  Flow.with_api (fun ~sim ~api:_ ~client ~dir ->
    let user_key = Sim.wallet_key 20 in
    let owner = Signing.Private_key.address user_key in
    let%bind token = Flow.login client user_key in
    let%bind () = Flow.approve_agent client ~token user_key in
    let ws_url token =
      Uri.of_string
        (sprintf
           "ws://127.0.0.1:%d/ws?token=%s"
           (Option.value_exn (Uri.port (C.base_url client)))
           token)
    in
    let%bind refused = Venue_net.Ws_client.connect ~url:(ws_url "bad") () in
    print_s [%sexp (Result.is_error refused : bool)];
    [%expect {| true |}];
    let%bind ws =
      Venue_net.Ws_client.connect ~url:(ws_url token) () >>| Or_error.ok_exn
    in
    let%bind me = next_message ws in
    print_s [%sexp (C.str "type" me : string), (C.str "me.agent.approved" me : string)];
    [%expect {| (me true) |}];
    let%bind _, follow =
      C.call
        client
        ~token
        `POST
        "/follows"
        ~body:
          (`Assoc
            [ "leader", `String (Address.to_string leader)
            ; "scale", `Assoc [ "kind", `String "equity_ratio" ]
            ; "caps", Api_types.Caps.yojson_of_t Api_types.Caps.default
            ])
    in
    let%bind pushed = next_message ws in
    print_s
      [%sexp
        (C.str "type" pushed : string)
        , (String.equal (C.str "follow.id" pushed) (C.str "id" follow) : bool)
        , (C.str "follow.state" pushed : string)];
    [%expect {| (follow true running) |}];
    (* A maker rests an ask; the user's agent lifts it, so the user's account fills. *)
    let config = Hl_client.Config.create ~base_url:sim.base_url () in
    let order ~is_buy : Hl_protocol.Order_request.t =
      { asset = Hl_protocol.Asset.of_int 0
      ; is_buy
      ; limit_px = Hl_protocol.Price.of_string "1000"
      ; sz = Hl_protocol.Size.of_string "0.01"
      ; reduce_only = false
      ; order_type = Hl_protocol.Order_type.gtc
      ; cloid = None
      }
    in
    let maker =
      Hl_client.Client.trading ~key:(Sim.wallet_key 21) ~is_mainnet:false config
    in
    let%bind (_ : Hl_protocol.Exchange_response.t Or_error.t) =
      Hl_client.Client.place_orders maker [ order ~is_buy:false ]
    in
    let agent =
      Hl_client.Client.trading_with_agent
        ~is_mainnet:false
        ~agent_key:(Flow.agent_key ~dir ~owner)
        ~account_address:owner
        config
    in
    let%bind (_ : Hl_protocol.Exchange_response.t Or_error.t) =
      Hl_client.Client.place_orders agent [ order ~is_buy:true ]
    in
    let%bind fill = next_message ws in
    print_s
      [%sexp
        (C.str "type" fill : string)
        , (C.str "fill.side" fill : string)
        , (C.str "fill.sz" fill : string)
        , (C.str "fill.dir" fill : string)];
    [%expect {| (fill buy 0.01 "Open Long") |}];
    Venue_net.Ws_client.close ws)
;;
