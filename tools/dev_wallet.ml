(* Signs what a browser wallet signs, for scripts/e2e-stack.sh and hl-copy-web's live
   smoke test: [personal_sign] of the login message and [eth_signTypedData_v4] of the
   approval typed data. The key comes from an environment variable and is never printed.
   Typed data for Hyperliquid's Mainnet is refused. *)

open! Core
module Signing = Hl_client.Signing

let key_param =
  let%map_open.Command var =
    flag
      "-key-env"
      (optional_with_default "HL_COPY_WALLET_KEY" string)
      ~doc:"VAR environment variable holding the wallet key (HL_COPY_WALLET_KEY)"
  in
  fun () -> Signing.Private_key.of_env ~var () |> Or_error.ok_exn
;;

let address =
  Command.basic
    ~summary:"Print the wallet's address, lowercase"
    (let%map_open.Command key = key_param in
     fun () ->
       print_endline
         (String.lowercase
            (Hl_protocol.Address.to_string (Signing.Private_key.address (key ())))))
;;

let personal_sign =
  Command.basic
    ~summary:"personal_sign the message on stdin (taken as is, no trailing newline added)"
    (let%map_open.Command key = key_param in
     fun () ->
       let message = In_channel.input_all In_channel.stdin in
       print_endline (Hl_copy_api.Wallet_signature.sign_personal (key ()) message))
;;

let sign_typed_data =
  Command.basic
    ~summary:"eth_signTypedData_v4 of the EIP-712 JSON on stdin (Testnet approvals only)"
    (let%map_open.Command key = key_param in
     fun () ->
       let typed = Yojson.Safe.from_string (In_channel.input_all In_channel.stdin) in
       print_endline
         (Hl_copy_api.Wallet_signature.sign_typed_data (key ()) typed |> Or_error.ok_exn))
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"Throwaway browser wallet for scripts and smoke tests (hl-sim, testnet)"
       [ "address", address
       ; "personal-sign", personal_sign
       ; "sign-typed-data", sign_typed_data
       ])
;;
