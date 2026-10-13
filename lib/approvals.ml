open! Core
open Async
open Hl_protocol
module Signing = Hl_client.Signing

let address_of_api a = Address.of_string (Api_types.Address.to_string a)
let address_to_api a = Api_types.Address.of_string (Address.to_string a)

let chain_to_api : User_signed_action.Hyperliquid_chain.t -> Api_types.Hyperliquid_chain.t
  = function
  | Mainnet -> Mainnet
  | Testnet -> Testnet
;;

let chain_of_api : Api_types.Hyperliquid_chain.t -> User_signed_action.Hyperliquid_chain.t
  = function
  | Mainnet -> Mainnet
  | Testnet -> Testnet
;;

let nonce_of_ms (ms : Api_types.Time_ms.t) = Float.iround_nearest_exn ms

let approve_agent_action (a : Api_types.Approve_agent.t) =
  User_signed_action.Approve_agent
    { hyperliquid_chain = chain_of_api a.hyperliquid_chain
    ; signature_chain_id = a.signature_chain_id
    ; agent_address = address_of_api a.agent_address
    ; agent_name = Some a.agent_name
    ; nonce = nonce_of_ms a.nonce
    }
;;

let approve_builder_fee_action (a : Api_types.Approve_builder_fee.t) =
  User_signed_action.Approve_builder_fee
    { hyperliquid_chain = chain_of_api a.hyperliquid_chain
    ; signature_chain_id = a.signature_chain_id
    ; max_fee_rate = a.max_fee_rate
    ; builder = address_of_api a.builder
    ; nonce = nonce_of_ms a.nonce
    }
;;

let agent_name_prefix = "hl-copy"
let default_agent_validity = Time_ns.Span.of_day 179.

let approve_agent_offer venue ~agent_address ~agent_name ~nonce =
  { Api_types.Approve_agent.hyperliquid_chain =
      chain_to_api (Venue.hyperliquid_chain venue)
  ; signature_chain_id = Venue.signature_chain_id venue
  ; agent_address = address_to_api agent_address
  ; agent_name
  ; nonce = Float.of_int nonce
  }
;;

let approve_builder_fee_offer venue ~builder ~max_fee_tenths_bp ~nonce =
  { Api_types.Approve_builder_fee.hyperliquid_chain =
      chain_to_api (Venue.hyperliquid_chain venue)
  ; signature_chain_id = Venue.signature_chain_id venue
  ; max_fee_rate = Builder_fee.percent_of_tenths_bp max_fee_tenths_bp
  ; builder = address_to_api builder
  ; nonce = Float.of_int nonce
  }
;;

let verify action ~signature ~owner =
  let open Or_error.Let_syntax in
  match User_signed_action.hyperliquid_chain action with
  | Mainnet -> Or_error.error_string "mainnet approvals are refused"
  | Testnet ->
    let%bind signature = Wallet_signature.of_hex signature in
    let%bind signer =
      Or_error.try_with_join (fun () -> Signing.recover_user_action action signature)
    in
    if Address.equal signer owner
    then Ok signature
    else
      Or_error.error_s
        [%message
          "signature is not from the logged-in wallet"
            (signer : Address.t)
            (owner : Address.t)]
;;

let submit venue ~owner action signature =
  let request =
    User_signed_request.create ~signature:(Signing.Signature.yojson_of_t signature) action
  in
  let config = { (Venue.config venue) with address = Some owner } in
  match%map
    Hl_client.Http.post_json
      ~headers:(Hl_client.Exchange.headers config)
      (Hl_client.Config.exchange_uri config)
      (User_signed_request.yojson_of_t request)
  with
  | Error _ as e -> e
  | Ok response ->
    (match Hl_client.Exchange.decode response with
     | Error _ as e -> e
     | Ok (Ok _) -> Ok ()
     | Ok (Err message) -> Or_error.error_s [%message "exchange rejected" message])
;;
