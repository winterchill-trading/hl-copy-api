open! Core

type t =
  { config : Hl_client.Config.t
  ; signature_chain_id : string
  }

let is_mainnet_url uri =
  match Uri.host uri with
  | None -> false
  | Some host ->
    let host = String.lowercase (String.chop_suffix_if_exists host ~suffix:".") in
    String.equal host "hyperliquid.xyz"
    || String.is_suffix host ~suffix:".hyperliquid.xyz"
;;

let create
  ?(signature_chain_id = Hl_protocol.User_signed_action.default_signature_chain_id)
  ~base_url
  ()
  =
  if is_mainnet_url base_url
  then
    Or_error.error_s
      [%message
        "refusing the Hyperliquid mainnet API; use hl-sim or testnet"
          ~base_url:(Uri.to_string base_url)]
  else Ok { config = Hl_client.Config.create ~base_url (); signature_chain_id }
;;

let config t = t.config
let base_url t = t.config.base_url
let hyperliquid_chain _ = Hl_protocol.User_signed_action.Hyperliquid_chain.Testnet
let signature_chain_id t = t.signature_chain_id
