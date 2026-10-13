open! Core
open Hl_protocol

type t =
  { key : string
  ; ttl : Time_ns.Span.t
  }

let create ?(ttl = Time_ns.Span.of_hr 24.) ~key () = { key; ttl }
let ttl t = t.ttl

module Claims = struct
  type t =
    { address : Address.t
    ; issued_ms : int
    ; expires_ms : int
    }
  [@@deriving sexp_of, compare, equal]
end

let ms_of_time time = Time_ns.to_int_ns_since_epoch time / 1_000_000

let mac t payload =
  Cryptokit.hash_string (Cryptokit.MAC.hmac_sha256 t.key) payload |> Hex.of_bytes
;;

let payload (c : Claims.t) =
  sprintf "%s.%d.%d" (Address.to_string c.address) c.issued_ms c.expires_ms
;;

let issue t address ~now =
  let issued_ms = ms_of_time now in
  let claims =
    { Claims.address
    ; issued_ms
    ; expires_ms = issued_ms + (Time_ns.Span.to_int_ns t.ttl / 1_000_000)
    }
  in
  let payload = payload claims in
  payload ^ "." ^ mac t payload, claims
;;

let equal_constant_time a b =
  String.length a = String.length b
  && String.foldi a ~init:0 ~f:(fun i acc c ->
       acc lor (Char.to_int c lxor Char.to_int b.[i]))
     = 0
;;

let is_address s =
  String.length s = 42
  && String.is_prefix s ~prefix:"0x"
  && String.for_all (String.drop_prefix s 2) ~f:Char.is_hex_digit
;;

let verify t ~now token =
  let invalid = Or_error.error_string "invalid session token" in
  match String.split token ~on:'.' with
  | [ address; issued; expires; mac' ] when is_address address ->
    (match Int.of_string_opt issued, Int.of_string_opt expires with
     | Some issued_ms, Some expires_ms ->
       let claims =
         { Claims.address = Address.of_string address; issued_ms; expires_ms }
       in
       if not (equal_constant_time (mac t (payload claims)) (String.lowercase mac'))
       then invalid
       else if ms_of_time now >= expires_ms
       then Or_error.error_string "session expired"
       else Ok claims
     | _ -> invalid)
  | _ -> invalid
;;

let of_authorization_header value =
  match String.lsplit2 (String.strip value) ~on:' ' with
  | Some (scheme, token) when String.Caseless.equal scheme "bearer" ->
    let token = String.strip token in
    if String.is_empty token then None else Some token
  | _ -> None
;;
