open! Core
open Hl_copy_api
module Address = Hl_protocol.Address

let key = Hl_client.Signing.Private_key.of_hex (String.make 64 '1') |> Or_error.ok_exn
let owner = Hl_client.Signing.Private_key.address key
let agent = Address.of_string "0xe139fba95d43a8acd9d4f58e7bcedc60e7dab4ee"
let builder = Address.of_string "0x53aa631b2d8d1fb87aa4dcff435c2dc6e62dbe27"

let venue =
  Venue.create ~base_url:(Uri.of_string "http://localhost:3000") () |> Or_error.ok_exn
;;

let agent_offer =
  Approvals.approve_agent_offer
    venue
    ~agent_address:agent
    ~agent_name:"hl-copy valid_until 1775000000000"
    ~nonce:1760257800000
;;

let fee_offer =
  Approvals.approve_builder_fee_offer
    venue
    ~builder
    ~max_fee_tenths_bp:10
    ~nonce:1760257800001
;;

let%expect_test "mainnet hosts are refused" =
  List.iter
    [ "https://api.hyperliquid.xyz"
    ; "https://API.Hyperliquid.xyz."
    ; "https://hyperliquid.xyz/exchange"
    ; "https://api.hyperliquid-testnet.xyz"
    ; "http://localhost:3000"
    ]
    ~f:(fun url ->
      print_s
        [%sexp
          (url : string)
          , (Venue.create ~base_url:(Uri.of_string url) () |> Result.is_ok : bool)]);
  [%expect
    {|
    (https://api.hyperliquid.xyz false)
    (https://API.Hyperliquid.xyz. false)
    (https://hyperliquid.xyz/exchange false)
    (https://api.hyperliquid-testnet.xyz true)
    (http://localhost:3000 true)
    |}]
;;

let%expect_test "offers and their typed data" =
  print_endline
    (Yojson.Safe.pretty_to_string (Api_types.Approve_agent.typed_data agent_offer));
  print_endline
    (Yojson.Safe.to_string (Api_types.Approve_builder_fee.typed_data fee_offer));
  [%expect
    {|
    {
      "domain": {
        "name": "HyperliquidSignTransaction",
        "version": "1",
        "chainId": 421614,
        "verifyingContract": "0x0000000000000000000000000000000000000000"
      },
      "types": {
        "EIP712Domain": [
          { "name": "name", "type": "string" },
          { "name": "version", "type": "string" },
          { "name": "chainId", "type": "uint256" },
          { "name": "verifyingContract", "type": "address" }
        ],
        "HyperliquidTransaction:ApproveAgent": [
          { "name": "hyperliquidChain", "type": "string" },
          { "name": "agentAddress", "type": "address" },
          { "name": "agentName", "type": "string" },
          { "name": "nonce", "type": "uint64" }
        ]
      },
      "primaryType": "HyperliquidTransaction:ApproveAgent",
      "message": {
        "hyperliquidChain": "Testnet",
        "agentAddress": "0xe139fba95d43a8acd9d4f58e7bcedc60e7dab4ee",
        "agentName": "hl-copy valid_until 1775000000000",
        "nonce": 1760257800000
      }
    }
    {"domain":{"name":"HyperliquidSignTransaction","version":"1","chainId":421614,"verifyingContract":"0x0000000000000000000000000000000000000000"},"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"HyperliquidTransaction:ApproveBuilderFee":[{"name":"hyperliquidChain","type":"string"},{"name":"maxFeeRate","type":"string"},{"name":"builder","type":"address"},{"name":"nonce","type":"uint64"}]},"primaryType":"HyperliquidTransaction:ApproveBuilderFee","message":{"hyperliquidChain":"Testnet","maxFeeRate":"0.01%","builder":"0x53aa631b2d8d1fb87aa4dcff435c2dc6e62dbe27","nonce":1760257800001}}
    |}]
;;

(* Signatures by eth_account 0.13 over the typed data printed above
   ([Account.sign_message(encode_typed_data(full_message=typed_data), key)]), as a browser
   wallet's [eth_signTypedData_v4] would return them. *)
let agent_signature =
  "0xb6f1393dd215006b1f943d03fca4bd67ade0d4622757ece5dffeeba656323b16708b58aae5d80a40b99fc6bee8029725010c6363c71270691c942b84042cb1b81c"
;;

let fee_signature =
  "0x90731425f3546315015f37ac9e213b644b72f25541aa73a8a5a418b550683ded4c8c007d7fc4507007d7494435e19325976c0dae25a9cf7c0d9e95ab5d9f15811b"
;;

let show_verify action ~signature ~owner =
  print_s
    [%sexp
      (Approvals.verify action ~signature ~owner |> Result.map ~f:(fun _ -> "verified")
       : string Or_error.t)]
;;

let%expect_test "wallet signatures over the typed data verify against the owner" =
  show_verify
    (Approvals.approve_agent_action agent_offer)
    ~signature:agent_signature
    ~owner;
  show_verify
    (Approvals.approve_builder_fee_action fee_offer)
    ~signature:fee_signature
    ~owner;
  [%expect {|
    (Ok verified)
    (Ok verified)
    |}];
  (* The same signature does not cover a different agent, nonce or signing chain. *)
  show_verify
    (Approvals.approve_agent_action { agent_offer with nonce = 1760257800002. })
    ~signature:agent_signature
    ~owner;
  show_verify
    (Approvals.approve_agent_action { agent_offer with signature_chain_id = "0xa4b1" })
    ~signature:agent_signature
    ~owner;
  [%expect
    {|
    (Error
     ("signature is not from the logged-in wallet"
      (signer 0xd3fab549703f9e9b1733a07b8ac7efb491b41eee)
      (owner 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)))
    (Error
     ("signature is not from the logged-in wallet"
      (signer 0xc87081a0a48c782fa4bccf0f466570a785578f25)
      (owner 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)))
    |}];
  show_verify
    (Approvals.approve_agent_action { agent_offer with hyperliquid_chain = Mainnet })
    ~signature:agent_signature
    ~owner;
  show_verify (Approvals.approve_agent_action agent_offer) ~signature:"0x1234" ~owner;
  [%expect
    {|
    (Error "mainnet approvals are refused")
    (Error "signature must be 0x followed by 130 hex digits")
    |}]
;;
