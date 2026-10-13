open! Core
open! Async
open Hl_copy_api
module Address = Hl_protocol.Address
module Signing = Hl_client.Signing
module C = Api_client

let master =
  Hl_copy_keystore.Sealed.Master_key.of_hex (String.make 64 'e') |> Or_error.ok_exn
;;

let builder = Address.of_string "0x53aa631b2d8d1fb87aa4dcff435c2dc6e62dbe27"

let with_api ?(configure = Fn.id) f =
  Sim.with_sim (fun sim ->
    Sim.with_dir (fun dir ->
      let config =
        configure
          { Server.Config.default with
            exchange_url = sim.base_url
          ; state_dir = dir ^/ "state"
          ; config_dir = dir ^/ "configs"
          ; builder = Some { address = builder; max_fee_tenths_bp = 10 }
          ; ws_status_interval = Time_ns.Span.of_min 10.
          }
      in
      let api = Server.create config ~master_key:master |> Or_error.ok_exn in
      let%bind http = Server.start api ~port:0 in
      let client = C.create ~port:(Cohttp_async.Server.listening_on http) in
      Monitor.protect
        (fun () -> f ~sim ~api ~client ~dir)
        ~finally:(fun () ->
          let%bind () = Server.close api in
          Cohttp_async.Server.close http)))
;;

let login client key =
  let address = Address.to_string (Signing.Private_key.address key) in
  let%bind _, challenge =
    C.call client `POST "/auth/challenge" ~body:(`Assoc [ "address", `String address ])
  in
  let message = C.str "message" challenge in
  let%map status, session =
    C.call
      client
      `POST
      "/auth/verify"
      ~body:
        (`Assoc
          [ "address", `String address
          ; "nonce", `String (C.str "nonce" challenge)
          ; "signature", `String (Wallet_signature.sign_personal key message)
          ])
  in
  if status <> 200 then raise_s [%message "login failed" (status : int)];
  C.str "token" session
;;

let approve_agent client ~token key =
  let%bind _, offer = C.call client ~token `POST "/agent/new" in
  let action =
    Approvals.approve_agent_action
      (Api_types.Approve_agent.t_of_yojson (C.path "approve_agent" offer))
  in
  let%map status, _ =
    C.call
      client
      ~token
      `POST
      "/agent/approved"
      ~body:
        (`Assoc
          [ "approve_agent", C.path "approve_agent" offer
          ; ( "signature"
            , `String (Wallet_signature.to_hex (Signing.sign_user_action key action)) )
          ])
  in
  if status <> 200 then raise_s [%message "agent approval failed" (status : int)]
;;

let agent_key ~dir ~owner =
  let keys =
    Hl_copy_keystore.Agent_keys.create ~dir:(dir ^/ "state" ^/ "agents") master
  in
  let entry =
    Hl_copy_keystore.Agent_keys.active keys ~owner |> Or_error.ok_exn |> Option.value_exn
  in
  Hl_copy_keystore.Agent_keys.secret keys entry
  |> Or_error.ok_exn
  |> Hl_copy_keystore.Sealed.to_hex
  |> Signing.Private_key.of_hex
  |> Or_error.ok_exn
;;
