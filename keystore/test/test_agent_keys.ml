open! Core
open Hl_protocol
open Hl_copy_keystore

let key = Sealed.Master_key.of_hex (String.make 64 'c') |> Or_error.ok_exn
let owner = Address.of_string "0x1111111111111111111111111111111111111111"
let other = Address.of_string "0x2222222222222222222222222222222222222222"
let agent n = Address.of_string (sprintf "0x%040x" n)

let with_store f =
  let dir = Filename_unix.temp_dir "agent-keys" "" in
  Exn.protect
    ~f:(fun () -> f (Agent_keys.create ~dir:(dir ^/ "keys") key))
    ~finally:(fun () ->
      ignore (Core_unix.system (sprintf "rm -rf %s" (Filename.quote dir))))
;;

let add t ~agent_address =
  Agent_keys.add_pending
    t
    ~owner
    ~agent_address
    ~agent_name:"hl-copy"
    ~nonce:1
    ~created_ms:1
    ~valid_until_ms:None
    ~secret:(String.make 32 (Address.to_string agent_address).[41])
  |> Or_error.ok_exn
;;

let statuses t =
  Agent_keys.entries t ~owner
  |> Or_error.ok_exn
  |> List.map ~f:(fun (e : Agent_keys.Entry.t) -> e.agent_address, e.status)
  |> [%sexp_of: (Address.t * Agent_keys.Status.t) list]
  |> print_s
;;

let%expect_test "pending, activate, rotate, revoke" =
  with_store (fun t ->
    print_s [%sexp (Agent_keys.entries t ~owner : Agent_keys.Entry.t list Or_error.t)];
    [%expect {| (Ok ()) |}];
    let (_ : Agent_keys.Entry.t) = add t ~agent_address:(agent 1) in
    let (_ : Agent_keys.Entry.t) =
      Agent_keys.activate t ~owner ~agent_address:(agent 1) |> Or_error.ok_exn
    in
    let (_ : Agent_keys.Entry.t) = add t ~agent_address:(agent 2) in
    statuses t;
    [%expect
      {|
      ((0x0000000000000000000000000000000000000002 Pending)
       (0x0000000000000000000000000000000000000001 Active))
      |}];
    let (_ : Agent_keys.Entry.t) =
      Agent_keys.activate t ~owner ~agent_address:(agent 2) |> Or_error.ok_exn
    in
    statuses t;
    [%expect
      {|
      ((0x0000000000000000000000000000000000000002 Active)
       (0x0000000000000000000000000000000000000001 Revoked))
      |}];
    let active = Agent_keys.active t ~owner |> Or_error.ok_exn |> Option.value_exn in
    print_s
      [%sexp (Agent_keys.secret t active |> Or_error.ok_exn |> Sealed.to_hex : string)];
    [%expect {| 3232323232323232323232323232323232323232323232323232323232323232 |}];
    let (_ : Agent_keys.Entry.t) =
      Agent_keys.revoke t ~owner ~agent_address:(agent 2) |> Or_error.ok_exn
    in
    print_s [%sexp (Agent_keys.active t ~owner : Agent_keys.Entry.t option Or_error.t)];
    [%expect {| (Ok ()) |}];
    print_s [%sexp (Agent_keys.owners t : Address.t list)];
    [%expect {| (0x1111111111111111111111111111111111111111) |}])
;;

let%expect_test "an agent address is never issued twice, even after revoking" =
  with_store (fun t ->
    let (_ : Agent_keys.Entry.t) = add t ~agent_address:(agent 1) in
    let (_ : Agent_keys.Entry.t) =
      Agent_keys.revoke t ~owner ~agent_address:(agent 1) |> Or_error.ok_exn
    in
    print_s
      [%sexp
        (Agent_keys.add_pending
           t
           ~owner
           ~agent_address:(agent 1)
           ~agent_name:"hl-copy"
           ~nonce:2
           ~created_ms:2
           ~valid_until_ms:None
           ~secret:(String.make 32 'x')
         : Agent_keys.Entry.t Or_error.t)];
    [%expect
      {|
      (Error
       ("agent address was already issued"
        (agent_address 0x0000000000000000000000000000000000000001)))
      |}])
;;

let%expect_test "the file holds no plaintext, is private, and does not open for another \
                 owner"
  =
  with_store (fun t ->
    let entry = add t ~agent_address:(agent 3) in
    let path = Agent_keys.path t ~owner in
    let contents = In_channel.read_all path in
    print_s
      [%sexp
        (String.is_substring contents ~substring:(Sealed.to_hex (String.make 32 '3'))
         : bool)
        , ((Core_unix.stat path).st_perm : int)];
    [%expect {| (false 384) |}];
    print_s
      [%sexp (Agent_keys.secret t { entry with owner = other } |> Result.is_ok : bool)];
    [%expect {| false |}])
;;
