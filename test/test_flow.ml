open! Core
open! Async
open Hl_copy_api
module Address = Hl_protocol.Address
module Signing = Hl_client.Signing
module C = Api_client

let leader = Address.of_string "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf"
let with_api = Flow.with_api
let login = Flow.login

(* Signs what the API offered, the way the browser hands typed data to the wallet. *)
let sign_offer key offer ~field ~to_action =
  let action = to_action (C.path field offer) in
  Wallet_signature.to_hex (Signing.sign_user_action key action)
;;

let agent_action json =
  Approvals.approve_agent_action (Api_types.Approve_agent.t_of_yojson json)
;;

let fee_action json =
  Approvals.approve_builder_fee_action (Api_types.Approve_builder_fee.t_of_yojson json)
;;

let caps =
  `Assoc
    [ "max_leverage", `Float 3.
    ; "max_notional_per_symbol", `Float 5000.
    ; "max_daily_loss", `Float 500.
    ; "allowlist", `List [ `String "BTC" ]
    ; "min_order_notional", `Float 10.
    ]
;;

let%expect_test "login, agent, builder fee, follow, pause, stop against hl-sim" =
  with_api (fun ~sim ~api:_ ~client ~dir ->
    let user_key = Sim.wallet_key 10 in
    let owner = Signing.Private_key.address user_key in
    let%bind status, health = C.call client `GET "/healthz" in
    print_s [%sexp (status : int), (C.str "status" health : string)];
    [%expect {| (200 ok) |}];
    (* Unauthenticated calls are refused. *)
    let%bind status, err = C.call client `GET "/me" in
    print_s [%sexp (status : int), (C.str "error" err : string)];
    [%expect {| (401 "missing session token") |}];
    (* A challenge signed by another wallet does not log in, and burns the nonce. *)
    let%bind _, challenge =
      C.call
        client
        `POST
        "/auth/challenge"
        ~body:(`Assoc [ "address", `String (Address.to_string owner) ])
    in
    let verify ~key =
      C.call
        client
        `POST
        "/auth/verify"
        ~body:
          (`Assoc
            [ "address", `String (Address.to_string owner)
            ; "nonce", `String (C.str "nonce" challenge)
            ; ( "signature"
              , `String (Wallet_signature.sign_personal key (C.str "message" challenge)) )
            ])
    in
    let%bind status, err = verify ~key:(Sim.wallet_key 11) in
    print_s [%sexp (status : int), (C.str "error" err : string)];
    let%bind status, err = verify ~key:user_key in
    print_s [%sexp (status : int), (C.str "error" err : string)];
    [%expect
      {|
      (401 "signature is not from this address")
      (401 "no outstanding challenge")
      |}];
    let%bind token = login client user_key in
    (* No follow before an agent is approved. *)
    let follow_body =
      `Assoc
        [ "leader", `String (Address.to_string leader)
        ; "scale", `Assoc [ "kind", `String "multiplier"; "value", `Float 0.5 ]
        ; "caps", caps
        ]
    in
    let%bind status, err = C.call client ~token `POST "/follows" ~body:follow_body in
    print_s [%sexp (status : int), (C.str "error" err : string)];
    [%expect {| (409 "approve an agent before following") |}];
    let%bind status, offer = C.call client ~token `POST "/agent/new" in
    print_s
      [%sexp
        (status : int)
        , (C.str "approve_agent.hyperliquid_chain" offer : string)
        , (C.str "approve_builder_fee.max_fee_rate" offer : string)
        , (C.str "typed_data.approve_agent.primaryType" offer : string)];
    [%expect {| (200 Testnet 0.01% HyperliquidTransaction:ApproveAgent) |}];
    (* The brief's shape: the signature alone, for the pending offer. *)
    let%bind status, agent =
      C.call
        client
        ~token
        `POST
        "/agent/approved"
        ~body:
          (`Assoc
            [ ( "signature"
              , `String
                  (sign_offer
                     user_key
                     offer
                     ~field:"approve_agent"
                     ~to_action:agent_action) )
            ])
    in
    print_s
      [%sexp
        (status : int)
        , (C.str "approved" agent : string)
        , (String.equal
             (C.str "agent_address" agent)
             (C.str "approve_agent.agent_address" offer)
           : bool)];
    [%expect {| (200 true true) |}];
    (* The Api_types shape: the action as signed plus the signature. *)
    let%bind status, agent =
      C.call
        client
        ~token
        `POST
        "/builder-fee"
        ~body:
          (`Assoc
            [ "approve_builder_fee", C.path "approve_builder_fee" offer
            ; ( "signature"
              , `String
                  (sign_offer
                     user_key
                     offer
                     ~field:"approve_builder_fee"
                     ~to_action:fee_action) )
            ])
    in
    print_s [%sexp (status : int), (C.str "builder_fee" agent : string)];
    [%expect {| (200 0.01%) |}];
    (* The engine's view: the sealed key opens and trades for the owner on the simulator,
       which verifies every signature. *)
    let agent_key = Flow.agent_key ~dir ~owner in
    let trading =
      Hl_client.Client.trading_with_agent
        ~is_mainnet:false
        ~agent_key
        ~account_address:owner
        (Hl_client.Config.create ~base_url:sim.base_url ())
    in
    let%bind placed =
      Hl_client.Client.place_orders
        trading
        [ { asset = Hl_protocol.Asset.of_int 0
          ; is_buy = true
          ; limit_px = Hl_protocol.Price.of_string "1000"
          ; sz = Hl_protocol.Size.of_string "0.01"
          ; reduce_only = false
          ; order_type = Hl_protocol.Order_type.gtc
          ; cloid = None
          }
        ]
    in
    print_s [%sexp (placed : Hl_protocol.Exchange_response.t Or_error.t)];
    let%bind orders =
      Hl_client.Info.open_orders
        ~user:owner
        (Hl_client.Config.create ~base_url:sim.base_url ())
    in
    print_s [%sexp (Or_error.map orders ~f:List.length : int Or_error.t)];
    [%expect
      {|
      (Ok (Ok (Order ((Resting (oid 1) (cloid ()))))))
      (Ok 1)
      |}];
    let%bind status, follow = C.call client ~token `POST "/follows" ~body:follow_body in
    let id = C.str "id" follow in
    print_s
      [%sexp
        (status : int)
        , (C.str "state" follow : string)
        , (C.str "scale.kind" follow : string)
        , (Sys_unix.file_exists_exn (dir ^/ "configs" ^/ id ^ ".sexp") : bool)];
    [%expect {| (201 running multiplier true) |}];
    let%bind status, err = C.call client ~token `POST "/follows" ~body:follow_body in
    print_s
      [%sexp
        (status : int)
        , (String.is_prefix (C.str "error" err) ~prefix:"(\"already following" : bool)];
    [%expect {| (409 true) |}];
    let%bind status, follow =
      C.call
        client
        ~token
        `PATCH
        ("/follows/" ^ id)
        ~body:(`Assoc [ "state", `String "paused" ])
    in
    print_s
      [%sexp
        (status : int)
        , (C.str "state" follow : string)
        , (String.is_substring
             (In_channel.read_all (dir ^/ "configs" ^/ id ^ ".sexp"))
             ~substring:"(paused true)"
           : bool)];
    [%expect {| (200 paused true) |}];
    let%bind status, follow = C.call client ~token `POST ("/follows/" ^ id ^ "/resume") in
    print_s [%sexp (status : int), (C.str "state" follow : string)];
    [%expect {| (200 running) |}];
    (* An execution algorithm: absent while immediate, rejected when execution-algos
       cannot read it, otherwise kept in its short form and written into the engine's
       config. *)
    let has_algo json =
      Option.is_some
        (Yojson.Safe.Util.member "algo" json
         |> function
         | `Null -> None
         | j -> Some j)
    in
    let patch body = C.call client ~token `PATCH ("/follows/" ^ id) ~body:(`Assoc body) in
    let config () = In_channel.read_all (dir ^/ "configs" ^/ id ^ ".sexp") in
    let%bind status, err = patch [ "algo", `String "twap:0s" ] in
    print_s
      [%sexp
        (has_algo follow : bool)
        , (status : int)
        , (String.is_prefix (C.str "error" err) ~prefix:"(\"invalid execution algorithm\""
           : bool)];
    let%bind status, follow = patch [ "algo", `String "twap:90s:3" ] in
    print_s
      [%sexp
        (status : int)
        , (C.str "algo" follow : string)
        , (C.str "state" follow : string)
        , (String.is_substring (config ()) ~substring:"(algo (Twap (duration_ms 90000)"
           : bool)];
    [%expect {|
      (false 400 true)
      (200 twap:90s:3 running true)
      |}];
    let%bind status, me = C.call client ~token `GET "/me" in
    let first_algo me =
      match C.path "follows" me with
      | `List [ f ] -> C.str "algo" f
      | _ -> ""
    in
    print_s
      [%sexp
        (status : int)
        , (C.str "account_value" me : string)
        , (C.str "agent.approved" me : string)
        , ((match C.path "follows" me with
            | `List l -> List.length l
            | _ -> -1)
           : int)
        , (first_algo me : string)];
    [%expect {| (200 1000000.0 true 1 twap:90s:3) |}];
    let%bind status, follow = patch [ "algo", `String "immediate" ] in
    print_s
      [%sexp
        (status : int)
        , (has_algo follow : bool)
        , (String.is_substring (config ()) ~substring:"algo" : bool)];
    [%expect {| (200 false false) |}];
    let%bind status, follow = C.call client ~token `DELETE ("/follows/" ^ id) in
    print_s
      [%sexp
        (status : int)
        , (C.str "state" follow : string)
        , (Sys_unix.file_exists_exn (dir ^/ "configs" ^/ id ^ ".sexp") : bool)];
    [%expect {| (200 stopped false) |}];
    (* Another user cannot see or touch the follow. *)
    let%bind other = login client (Sim.wallet_key 12) in
    let%bind status, _ = C.call client ~token:other `GET ("/follows/" ^ id) in
    let%bind status', _ = C.call client ~token:other `DELETE ("/follows/" ^ id) in
    print_s [%sexp (status : int), (status' : int)];
    [%expect {| (404 404) |}];
    return ())
;;
