open! Core
open Hl_copy_api

let address = Hl_protocol.Address.of_string "0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"
let session = Session.create ~ttl:(Time_ns.Span.of_min 10.) ~key:(String.make 32 'k') ()
let t0 = Time_ns.of_int_ns_since_epoch 1_760_000_000_000_000_000
let at min = Time_ns.add t0 (Time_ns.Span.of_min min)

let show token ~now =
  print_s [%sexp (Session.verify session ~now token : Session.Claims.t Or_error.t)]
;;

let%expect_test "issue and verify" =
  let token, claims = Session.issue session address ~now:t0 in
  print_endline token;
  [%expect
    {| 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a.1760000000000.1760000600000.24ad5fd7b9f3b074da168511067cb8683af752a23e74d85620b3df33535f3cb7 |}];
  print_s [%sexp (claims : Session.Claims.t)];
  [%expect
    {|
    ((address 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)
     (issued_ms 1760000000000) (expires_ms 1760000600000))
    |}];
  show token ~now:(at 9.);
  [%expect
    {|
    (Ok
     ((address 0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a)
      (issued_ms 1760000000000) (expires_ms 1760000600000)))
    |}];
  show token ~now:(at 10.);
  [%expect {| (Error "session expired") |}]
;;

let%expect_test "forged, extended and foreign tokens are rejected" =
  let token, _ = Session.issue session address ~now:t0 in
  let other = Session.create ~key:(String.make 32 'x') () in
  let foreign, _ = Session.issue other address ~now:t0 in
  let extended =
    String.substr_replace_first token ~pattern:"1760000600000" ~with_:"1860000600000"
  in
  let other_user = String.substr_replace_first token ~pattern:"0x19e7" ~with_:"0x29e7" in
  List.iter [ foreign; extended; other_user; "garbage"; "" ] ~f:(show ~now:t0);
  [%expect
    {|
    (Error "invalid session token")
    (Error "invalid session token")
    (Error "invalid session token")
    (Error "invalid session token")
    (Error "invalid session token")
    |}]
;;

let%expect_test "authorization header" =
  List.iter
    [ "Bearer abc"; "bearer  abc "; "Basic abc"; "Bearer"; "Bearer " ]
    ~f:(fun h -> print_s [%sexp (Session.of_authorization_header h : string option)]);
  [%expect {|
    (abc)
    (abc)
    ()
    ()
    ()
    |}]
;;
