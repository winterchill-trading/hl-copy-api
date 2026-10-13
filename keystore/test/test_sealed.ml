open! Core
open Hl_copy_keystore

let key = Sealed.Master_key.of_hex (String.make 64 'a') |> Or_error.ok_exn
let other_key = Sealed.Master_key.of_hex (String.make 64 'b') |> Or_error.ok_exn
let salt = String.make 24 '\x07'

(* The same box comes out of an independent Python implementation (pycryptodome ChaCha20
   with an 8-byte zero nonce, hmac and hashlib), so the layout is not only
   self-consistent. *)
let%expect_test "fixed salt gives a fixed box" =
  let box = Sealed.seal ~salt key ~aad:"owner" "secret" in
  print_endline (Sealed.to_hex box);
  [%expect
    {| 01070707070707070707070707070707070707070707070707483d2da6dc814ac101dd9992d32db1e4a4b8e141af7971bfcf20590eebae904f4f1cd536dabb |}];
  print_s [%sexp (Sealed.open_ key ~aad:"owner" box : string Or_error.t)];
  [%expect {| (Ok secret) |}]
;;

let%expect_test "wrong key, wrong aad, tampering and truncation all fail" =
  let box = Sealed.seal key ~aad:"owner" "secret" in
  let flip i =
    String.mapi box ~f:(fun j c ->
      if i = j then Char.of_int_exn (Char.to_int c lxor 1) else c)
  in
  let show box ~key ~aad =
    print_s [%sexp (Sealed.open_ key ~aad box : string Or_error.t)]
  in
  show box ~key:other_key ~aad:"owner";
  show box ~key ~aad:"other";
  show (flip 0) ~key ~aad:"owner";
  show (flip 30) ~key ~aad:"owner";
  show (flip (String.length box - 1)) ~key ~aad:"owner";
  show (String.prefix box 40) ~key ~aad:"owner";
  [%expect
    {|
    (Error "cannot open sealed box")
    (Error "cannot open sealed box")
    (Error "cannot open sealed box")
    (Error "cannot open sealed box")
    (Error "cannot open sealed box")
    (Error "cannot open sealed box")
    |}]
;;

let%expect_test "two seals of one secret differ" =
  let a = Sealed.seal key ~aad:"" "secret" in
  let b = Sealed.seal key ~aad:"" "secret" in
  print_s [%sexp (String.equal a b : bool), (String.length a : int)];
  [%expect {| (false 63) |}]
;;

let%expect_test "master key parsing" =
  let show s =
    print_s [%sexp (Sealed.Master_key.of_hex s : Sealed.Master_key.t Or_error.t)]
  in
  show ("0x" ^ String.make 64 'F');
  show (String.make 62 'a');
  show (String.make 64 'g');
  [%expect
    {|
    (Ok "<master key>")
    (Error "master key must be 64 hex digits (32 bytes)")
    (Error "master key must be 64 hex digits (32 bytes)")
    |}]
;;

let%test_unit "open_ inverts seal" =
  Quickcheck.test
    ~sexp_of:[%sexp_of: string * string]
    (Quickcheck.Generator.tuple2 String.quickcheck_generator String.quickcheck_generator)
    ~f:(fun (aad, plaintext) ->
      [%test_result: string Or_error.t]
        (Sealed.open_ key ~aad (Sealed.seal ~salt key ~aad plaintext))
        ~expect:(Ok plaintext))
;;
