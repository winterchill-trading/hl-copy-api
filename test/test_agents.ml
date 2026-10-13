open! Core
open! Async
open Hl_copy_api
module Address = Hl_protocol.Address
module Agent_keys = Hl_copy_keystore.Agent_keys
module Signing = Hl_client.Signing

let master =
  Hl_copy_keystore.Sealed.Master_key.of_hex (String.make 64 'd') |> Or_error.ok_exn
;;

let builder = Address.of_string "0x53aa631b2d8d1fb87aa4dcff435c2dc6e62dbe27"

let setup (sim : Sim.t) dir =
  let venue = Venue.create ~base_url:sim.base_url () |> Or_error.ok_exn in
  Agents.create
    ~builder:{ address = builder; max_fee_tenths_bp = 10 }
    ~keys:(Agent_keys.create ~dir:(dir ^/ "agents") master)
    venue
;;

(* What the browser does: sign the offered typed data with the user's wallet. *)
let wallet_sign key action = Wallet_signature.to_hex (Signing.sign_user_action key action)
let print_result r = print_s [%sexp (Result.map r ~f:(fun _ -> "ok") : string Or_error.t)]

let%expect_test "offer, sign, approve on the simulator, rotate" =
  Sim.with_sim (fun sim ->
    Sim.with_dir (fun dir ->
      let agents = setup sim dir in
      let user_key = Sim.wallet_key 1 in
      let owner = Signing.Private_key.address user_key in
      let now = Time_ns.now () in
      let offer = Agents.offer agents ~owner ~now |> Or_error.ok_exn in
      let again = Agents.offer agents ~owner ~now |> Or_error.ok_exn in
      print_s
        [%sexp
          (Api_types.Approve_agent.equal offer.approve_agent again.approve_agent : bool)
          , (String.is_prefix
               offer.approve_agent.agent_name
               ~prefix:"hl-copy valid_until "
             : bool)
          , (Option.map offer.approve_builder_fee ~f:(fun f -> f.max_fee_rate)
             : string option)];
      [%expect {| (true true (0.01%)) |}];
      (* A signature by another wallet is refused before anything is sent. *)
      let%bind r =
        Agents.approve_agent
          agents
          ~owner
          ~signature:
            (wallet_sign
               (Sim.wallet_key 2)
               (Approvals.approve_agent_action offer.approve_agent))
          ()
      in
      print_s
        [%sexp
          (Result.map_error r ~f:(fun e ->
             Error.to_string_hum e |> String.is_substring ~substring:"logged-in wallet")
           |> Result.is_error
           : bool)];
      [%expect {| true |}];
      let%bind r =
        Agents.approve_agent
          agents
          ~owner
          ~signature:
            (wallet_sign user_key (Approvals.approve_agent_action offer.approve_agent))
          ()
      in
      print_result r;
      [%expect {| (Ok ok) |}];
      let agent = Approvals.address_of_api offer.approve_agent.agent_address in
      print_s
        [%sexp
          (Hl_sim.Agents.owner (Hl_sim.Server.agents sim.server) agent
           |> Option.map ~f:(Address.equal owner)
           : bool option)];
      [%expect {| (true) |}];
      let%bind r =
        Agents.approve_builder_fee
          agents
          ~owner
          ~signature:
            (wallet_sign
               user_key
               (Approvals.approve_builder_fee_action
                  (Option.value_exn offer.approve_builder_fee)))
          ()
      in
      print_result r;
      print_s
        [%sexp
          (Hl_sim.Agents.max_builder_fee
             (Hl_sim.Server.agents sim.server)
             ~user:owner
             ~builder
           : int)
          , (Agents.builder_fee_approved agents ~owner : bool)];
      [%expect {|
        (Ok ok)
        (10 true)
        |}];
      (* The stored key is the agent's: it opens and has the agent's address. *)
      let active = Agents.active agents ~owner |> Option.value_exn in
      let key =
        Agent_keys.secret (Agents.keys agents) active
        |> Or_error.ok_exn
        |> Hl_copy_keystore.Sealed.to_hex
        |> Signing.Private_key.of_hex
        |> Or_error.ok_exn
      in
      print_s [%sexp (Address.equal (Signing.Private_key.address key) agent : bool)];
      [%expect {| true |}];
      (* Rotation: a new offer is a new key, and approving it revokes the old one. *)
      let offer2 =
        Agents.offer agents ~owner ~now:(Time_ns.add now (Time_ns.Span.of_ms 1.))
        |> Or_error.ok_exn
      in
      print_s
        [%sexp
          (Api_types.Address.equal
             offer.approve_agent.agent_address
             offer2.approve_agent.agent_address
           : bool)];
      [%expect {| false |}];
      let%bind r =
        Agents.approve_agent
          agents
          ~owner
          ~signature:
            (wallet_sign user_key (Approvals.approve_agent_action offer2.approve_agent))
          ()
      in
      print_result r;
      print_s
        [%sexp
          (Agent_keys.entries (Agents.keys agents) ~owner
           |> Or_error.ok_exn
           |> List.map ~f:(fun (e : Agent_keys.Entry.t) -> e.status)
           : Agent_keys.Status.t list)];
      [%expect {|
        (Ok ok)
        (Active Revoked)
        |}];
      return ()))
;;

let%expect_test "approving without an offer, or with a changed action, fails" =
  Sim.with_sim (fun sim ->
    Sim.with_dir (fun dir ->
      let agents = setup sim dir in
      let user_key = Sim.wallet_key 3 in
      let owner = Signing.Private_key.address user_key in
      let%bind r = Agents.approve_agent agents ~owner ~signature:"0x00" () in
      print_s [%sexp (r : Agent_keys.Entry.t Or_error.t)];
      [%expect {| (Error "no pending agent; request an offer first") |}];
      let offer = Agents.offer agents ~owner ~now:(Time_ns.now ()) |> Or_error.ok_exn in
      let changed = { offer.approve_agent with agent_name = "something else" } in
      let%bind r =
        Agents.approve_agent
          agents
          ~owner
          ~signed:changed
          ~signature:(wallet_sign user_key (Approvals.approve_agent_action changed))
          ()
      in
      print_s
        [%sexp
          (Result.error r
           |> Option.map ~f:(fun e ->
             String.is_substring
               (Error.to_string_hum e)
               ~substring:"does not match the pending offer")
           : bool option)];
      [%expect {| (true) |}];
      (* A wallet that signs under its own chain id is accepted. *)
      let on_arbitrum = { offer.approve_agent with signature_chain_id = "0xa4b1" } in
      let%bind r =
        Agents.approve_agent
          agents
          ~owner
          ~signed:on_arbitrum
          ~signature:(wallet_sign user_key (Approvals.approve_agent_action on_arbitrum))
          ()
      in
      print_result r;
      [%expect {| (Ok ok) |}];
      return ()))
;;
