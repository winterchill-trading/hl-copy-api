open! Core
module Signing = Hl_client.Signing

let personal_message_digest message =
  Hl_client.Keccak.digest
    (sprintf "\x19Ethereum Signed Message:\n%d%s" (String.length message) message)
;;

let of_hex hex =
  let hex = String.chop_prefix_if_exists (String.strip hex) ~prefix:"0x" in
  if String.length hex <> 130 || not (String.for_all hex ~f:Char.is_hex_digit)
  then Or_error.error_string "signature must be 0x followed by 130 hex digits"
  else (
    let v = Int.of_string ("0x" ^ String.sub hex ~pos:128 ~len:2) in
    let v = if v < 27 then v + 27 else v in
    if v <> 27 && v <> 28
    then Or_error.error_s [%message "signature recovery id out of range" (v : int)]
    else
      Ok
        { Signing.Signature.r = "0x" ^ String.sub hex ~pos:0 ~len:64
        ; s = "0x" ^ String.sub hex ~pos:64 ~len:64
        ; v
        })
;;

(* [Signing.Signature] keeps [r] and [s] without leading zeros, as the exchange wants. *)
let word hex =
  let hex = String.chop_prefix_if_exists hex ~prefix:"0x" in
  String.make (64 - String.length hex) '0' ^ String.lowercase hex
;;

let to_hex (s : Signing.Signature.t) = sprintf "0x%s%s%02x" (word s.r) (word s.s) s.v

let recover_personal ~message signature =
  let open Or_error.Let_syntax in
  let%bind signature = of_hex signature in
  Signing.recover ~digest:(personal_message_digest message) signature
;;

let sign_personal key message =
  to_hex (Signing.sign_digest key (personal_message_digest message))
;;
