open! Core
open Hl_copy_api

(* Vector from eth_account 0.13 ([Account.sign_message(encode_defunct(text=msg), key)])
   with the throwaway key 0x1111...11. *)
let key = Hl_client.Signing.Private_key.of_hex (String.make 64 '1') |> Or_error.ok_exn
let message = "hl-copy wants you to sign in.\nNonce: 1"

let eth_account_signature =
  "0xfb811c5a5596944bd3f10f9f01bcfa642d8f99edb2216e06d1ec271e8a6cf0b06a39da537cf3b92fce97547738a064acbe19029412a9e906dcac4d1bab05b7a21b"
;;

let%expect_test "personal_sign digest, signature and recovery match eth_account" =
  print_endline (Hex.of_bytes (Wallet_signature.personal_message_digest message));
  [%expect {| db34bcbecbd6e8cb6815562a18355fcc08b0907dfbb6f5ba66934c45d4acd0eb |}];
  print_endline (Wallet_signature.sign_personal key message);
  [%expect
    {| 0xfb811c5a5596944bd3f10f9f01bcfa642d8f99edb2216e06d1ec271e8a6cf0b06a39da537cf3b92fce97547738a064acbe19029412a9e906dcac4d1bab05b7a21b |}];
  print_s
    [%sexp
      (Wallet_signature.recover_personal ~message eth_account_signature
       : Hl_protocol.Address.t Or_error.t)];
  [%expect {| (Ok 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a) |}]
;;

let%expect_test "recovery id 0/1 is accepted, other bytes and lengths are not" =
  let with_v v = String.drop_suffix eth_account_signature 2 ^ v in
  let show s =
    print_s
      [%sexp
        (Wallet_signature.recover_personal ~message s : Hl_protocol.Address.t Or_error.t)]
  in
  show (with_v "00");
  show (with_v "02");
  show (String.drop_suffix eth_account_signature 2);
  show (with_v "zz");
  [%expect
    {|
    (Ok 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)
    (Error ("signature recovery id out of range" (v 29)))
    (Error "signature must be 0x followed by 130 hex digits")
    (Error "signature must be 0x followed by 130 hex digits")
    |}]
;;

let%expect_test "a different message recovers to a different address" =
  print_s
    [%sexp
      (Wallet_signature.recover_personal ~message:(message ^ "!") eth_account_signature
       |> Or_error.map ~f:(fun a ->
         String.equal
           (Hl_protocol.Address.to_string a)
           "0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a")
       : bool Or_error.t)];
  [%expect {| (Ok false) |}]
;;

let%expect_test "typed data as the browser gets it signs like the approval action" =
  let offer =
    { Api_types.Approve_agent.hyperliquid_chain = Testnet
    ; signature_chain_id = "0x66eee"
    ; agent_address = Api_types.Address.of_string ("0x" ^ String.make 40 '2')
    ; agent_name = "hl-copy valid_until 1807343157720"
    ; nonce = 1760257800000.
    }
  in
  let typed = Api_types.Approve_agent.typed_data offer in
  let action = Approvals.approve_agent_action offer in
  let via_json = Wallet_signature.typed_data_digest typed |> Or_error.ok_exn in
  print_s
    [%message
      ""
        ~same_digest:
          (String.equal via_json (Hl_client.Signing.user_action_digest action) : bool)
        ~same_signature:
          (String.equal
             (Wallet_signature.sign_typed_data key typed |> Or_error.ok_exn)
             (Wallet_signature.to_hex (Hl_client.Signing.sign_user_action key action))
           : bool)];
  [%expect {| ((same_digest true) (same_signature true)) |}];
  let mainnet =
    Api_types.Approve_agent.typed_data { offer with hyperliquid_chain = Mainnet }
  in
  print_s [%sexp (Wallet_signature.typed_data_digest mainnet : string Or_error.t)];
  [%expect {| (Error ("typed data" (Failure "refusing to sign for \"Mainnet\""))) |}]
;;
