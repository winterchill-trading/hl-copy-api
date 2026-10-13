open! Core

let to_hex s = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) s

let of_hex s =
  let s = String.chop_prefix_if_exists s ~prefix:"0x" in
  if String.length s % 2 <> 0 || not (String.for_all s ~f:Char.is_hex_digit)
  then Or_error.error_string "not a hex string"
  else
    Or_error.try_with (fun () -> Cryptokit.transform_string (Cryptokit.Hexa.decode ()) s)
;;

let hmac ~key data = Cryptokit.hash_string (Cryptokit.MAC.hmac_sha256 key) data

module Master_key = struct
  type t =
    { enc : string
    ; mac : string
    ; master : string
    }

  let sexp_of_t _ = Sexp.Atom "<master key>"

  let of_hex hex =
    match of_hex (String.strip hex) with
    | Ok key when String.length key = 32 ->
      Ok
        { enc = hmac ~key "hl-copy-keystore v1 encryption"
        ; mac = hmac ~key "hl-copy-keystore v1 authentication"
        ; master = key
        }
    | Ok _ | Error _ ->
      Or_error.error_string "master key must be 64 hex digits (32 bytes)"
  ;;

  let of_env ?(var = "HL_COPY_MASTER_KEY") () =
    match Sys.getenv var with
    | None -> Or_error.errorf "%s is not set" var
    | Some hex -> Or_error.tag (of_hex hex) ~tag:var
  ;;

  let derive t ~label = hmac ~key:t.master ("hl-copy-keystore v1 " ^ label)
end

let random_bytes n = Cryptokit.Random.string Cryptokit.Random.secure_rng n
let version = '\x01'
let salt_length = 24
let tag_length = 32

let chacha ~(key : Master_key.t) ~salt data =
  Cryptokit.transform_string
    (Cryptokit.Cipher.chacha20 (hmac ~key:key.enc salt) Encrypt)
    data
;;

let tag ~(key : Master_key.t) ~salt ~aad ciphertext =
  hmac
    ~key:key.mac
    (String.concat
       [ String.of_char version
       ; salt
       ; sprintf "%08x" (String.length aad)
       ; aad
       ; ciphertext
       ])
;;

let seal ?salt key ~aad plaintext =
  let salt = Option.value_or_thunk salt ~default:(fun () -> random_bytes salt_length) in
  if String.length salt <> salt_length
  then raise_s [%message "salt must be 24 bytes" (String.length salt : int)];
  let ciphertext = chacha ~key ~salt plaintext in
  String.concat
    [ String.of_char version; salt; ciphertext; tag ~key ~salt ~aad ciphertext ]
;;

(* Constant-time comparison: the time taken does not depend on where the tags differ. *)
let equal_constant_time a b =
  String.length a = String.length b
  && String.foldi a ~init:0 ~f:(fun i acc c ->
       acc lor (Char.to_int c lxor Char.to_int b.[i]))
     = 0
;;

let open_ key ~aad box =
  let n = String.length box in
  if n < 1 + salt_length + tag_length || not (Char.equal box.[0] version)
  then Or_error.error_string "cannot open sealed box"
  else (
    let salt = String.sub box ~pos:1 ~len:salt_length in
    let ciphertext =
      String.sub box ~pos:(1 + salt_length) ~len:(n - 1 - salt_length - tag_length)
    in
    let expected = String.suffix box tag_length in
    if equal_constant_time expected (tag ~key ~salt ~aad ciphertext)
    then Ok (chacha ~key ~salt ciphertext)
    else Or_error.error_string "cannot open sealed box")
;;
