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

module Value = Hl_protocol.User_signed_action.Eip712.Value

let typed_data_digest typed =
  Or_error.try_with (fun () ->
    let member name json =
      match json with
      | `Assoc fields ->
        (match List.Assoc.find fields ~equal:String.equal name with
         | Some v -> v
         | None -> failwithf "missing %s" name ())
      | _ -> failwithf "%s of a non-object" name ()
    in
    let to_string = function
      | `String s -> s
      | json -> failwithf "not a string: %s" (Yojson.Safe.to_string json) ()
    in
    let to_int = function
      | `Int i -> i
      | `Intlit s -> Int.of_string s
      | `Float f when Float.is_integer f -> Float.to_int f
      | `String s -> Int.of_string s (* hex such as "0x66eee", or decimal *)
      | json -> failwithf "not an integer: %s" (Yojson.Safe.to_string json) ()
    in
    let domain = member "domain" typed in
    let name = to_string (member "name" domain) in
    if not (String.equal name Hl_protocol.User_signed_action.Eip712.domain_name)
    then failwithf "domain %s is not supported" name ();
    let primary_type = to_string (member "primaryType" typed) in
    let message = member "message" typed in
    (match member "hyperliquidChain" message with
     | `String "Testnet" -> ()
     | json -> failwithf "refusing to sign for %s" (Yojson.Safe.to_string json) ());
    let fields =
      match member primary_type (member "types" typed) with
      | `List fields ->
        List.map fields ~f:(fun field ->
          let name = to_string (member "name" field) in
          let value = member name message in
          ( name
          , match to_string (member "type" field) with
            | "string" -> Value.String (to_string value)
            | "address" -> Address (Hl_protocol.Address.of_string (to_string value))
            | "uint64" -> Uint64 (to_int value)
            | other -> failwithf "field type %s is not supported" other () ))
      | _ -> failwith "the primary type's fields are not a list"
    in
    Signing.user_signed_digest
      ~chain_id:(to_int (member "chainId" domain))
      ~primary_type
      fields)
  |> Or_error.tag ~tag:"typed data"
;;

let sign_typed_data key typed =
  let%map.Or_error digest = typed_data_digest typed in
  to_hex (Signing.sign_digest key digest)
;;
