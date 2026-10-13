open! Core
open Hl_copy_api
module Address = Hl_protocol.Address

let alice = Address.of_string "0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"
let bob = Address.of_string "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
let t0 = Time_ns.of_int_ns_since_epoch 1_760_000_000_000_000_000
let at min = Time_ns.add t0 (Time_ns.Span.of_min min)

let create () =
  Challenge.create
    ~domain:"localhost:8080"
    ~uri:"http://localhost:8080"
    ~chain_id:421614
    ()
;;

let%expect_test "EIP-55 checksums match eth_utils" =
  (* Expected values from eth_utils.to_checksum_address; the second is EIP-55's own
     example. *)
  List.iter [ alice; bob ] ~f:(fun a -> print_endline (Challenge.checksum_address a));
  [%expect
    {|
    0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A
    0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed
    |}]
;;

let%expect_test "message layout" =
  let t = create () in
  let c = Challenge.issue ~nonce:"0123456789abcdef" t alice ~now:t0 in
  print_endline c.message;
  print_s [%sexp (c.nonce : string), (c.expires_at : float)];
  [%expect
    {|
    localhost:8080 wants you to sign in with your Ethereum account:
    0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A

    Sign in to hl-copy. This request does not trigger a transaction or cost any fee.

    URI: http://localhost:8080
    Version: 1
    Chain ID: 421614
    Nonce: 0123456789abcdef
    Issued At: 2025-10-09T08:53:20.000000000Z
    Expiration Time: 2025-10-09T08:58:20.000000000Z
    (0123456789abcdef 1760000300000)
    |}]
;;

let show r =
  print_s [%sexp (Result.map r ~f:(fun m -> String.length m > 0) : bool Or_error.t)]
;;

let%expect_test "single use, bound to the address, expiring" =
  let t = create () in
  let c = Challenge.issue t alice ~now:t0 in
  print_s [%sexp (String.length c.nonce : int)];
  [%expect {| 16 |}];
  show (Challenge.consume t bob ~nonce:(Some c.nonce) ~now:t0);
  show (Challenge.consume t alice ~nonce:(Some c.nonce) ~now:t0);
  show (Challenge.consume t alice ~nonce:(Some c.nonce) ~now:t0);
  [%expect
    {|
    (Error "no outstanding challenge")
    (Ok true)
    (Error "no outstanding challenge")
    |}];
  let c = Challenge.issue t alice ~now:t0 in
  show (Challenge.consume t alice ~nonce:(Some c.nonce) ~now:(at 5.));
  [%expect {| (Error "challenge expired") |}];
  print_s [%sexp (Challenge.outstanding t : int)];
  [%expect {| 0 |}]
;;

let%expect_test "without a nonce the newest challenge of the address is used" =
  let t = create () in
  let (_ : Api_types.Auth.Challenge.t) = Challenge.issue ~nonce:"a1" t alice ~now:t0 in
  let (_ : Api_types.Auth.Challenge.t) = Challenge.issue ~nonce:"a2" t alice ~now:t0 in
  let (_ : Api_types.Auth.Challenge.t) = Challenge.issue ~nonce:"b1" t bob ~now:t0 in
  let nonce_of r =
    Or_error.map r ~f:(fun m ->
      List.find_map_exn (String.split_lines m) ~f:(String.chop_prefix ~prefix:"Nonce: "))
  in
  print_s
    [%sexp (nonce_of (Challenge.consume t alice ~nonce:None ~now:t0) : string Or_error.t)];
  print_s
    [%sexp (nonce_of (Challenge.consume t alice ~nonce:None ~now:t0) : string Or_error.t)];
  print_s
    [%sexp (nonce_of (Challenge.consume t alice ~nonce:None ~now:t0) : string Or_error.t)];
  [%expect {|
    (Ok a2)
    (Ok a1)
    (Error "no outstanding challenge")
    |}]
;;

let%expect_test "expired challenges are pruned and the store is bounded" =
  let t = Challenge.create ~max_outstanding:3 ~domain:"d" ~uri:"u" ~chain_id:1 () in
  for i = 1 to 5 do
    ignore
      (Challenge.issue ~nonce:(Int.to_string i) t alice ~now:t0
       : Api_types.Auth.Challenge.t)
  done;
  print_s [%sexp (Challenge.outstanding t : int)];
  show (Challenge.consume t alice ~nonce:(Some "1") ~now:t0);
  [%expect {|
    3
    (Error "no outstanding challenge")
    |}];
  ignore (Challenge.issue t bob ~now:(at 6.) : Api_types.Auth.Challenge.t);
  print_s [%sexp (Challenge.outstanding t : int)];
  [%expect {| 1 |}]
;;
