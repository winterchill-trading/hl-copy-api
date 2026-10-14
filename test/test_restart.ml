open! Core
open! Async
open Hl_copy_api
module Address = Hl_protocol.Address
module Signing = Hl_client.Signing
module C = Api_client

let leader = Address.of_string "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf"

let ls dir =
  print_s
    [%sexp
      (Sys_unix.readdir dir |> Array.to_list |> List.sort ~compare:String.compare
       : string list)]
;;

(* One API process: a server on [store] until [f] returns. *)
let run_api ~(sim : Sim.t) ~dir ~database_url f =
  let%bind pg = Store_pg.connect ~database_url () >>| Or_error.ok_exn in
  let config =
    { Server.Config.default with
      exchange_url = sim.base_url
    ; state_dir = dir ^/ "state"
    ; config_dir = dir ^/ "configs"
    ; ws_status_interval = Time_ns.Span.of_min 10.
    }
  in
  let%bind api =
    Server.create config ~master_key:Flow.master ~store:(Store_pg.store pg)
    >>| Or_error.ok_exn
  in
  let%bind http = Server.start api ~port:0 in
  let client = C.create ~port:(Cohttp_async.Server.listening_on http) in
  Monitor.protect
    (fun () -> f client)
    ~finally:(fun () ->
      let%bind () = Server.close api in
      let%bind () = Cohttp_async.Server.close http in
      Store_pg.close pg)
;;

let%expect_test "follows and agents survive a restart; the engine's files are rebuilt" =
  Sim.with_sim (fun sim ->
    Sim.with_dir (fun dir ->
      let%bind database_url = Test_db.fresh_url () in
      let user_key = Sim.wallet_key 21 in
      let owner = Signing.Private_key.address user_key in
      let%bind token, follow_id =
        run_api ~sim ~dir ~database_url (fun client ->
          let%bind token = Flow.login client user_key in
          let%bind () = Flow.approve_agent client ~token user_key in
          let%map status, follow =
            C.call
              client
              ~token
              `POST
              "/follows"
              ~body:
                (`Assoc
                  [ "leader", `String (Address.to_string leader)
                  ; "scale", `Assoc [ "kind", `String "equity_ratio" ]
                  ; "caps", Api_types.Caps.yojson_of_t Api_types.Caps.default
                  ])
          in
          print_s [%sexp (status : int)];
          token, C.str "id" follow)
      in
      [%expect {| 201 |}];
      (* Between the two runs the engine's inputs are lost or polluted: the key file and
         the follow's config are deleted, and a config nobody asked for appears. *)
      let key_file = dir ^/ "state" ^/ "agents" ^/ Address.to_string owner ^ ".key" in
      let agent_before = Flow.agent_key ~dir ~owner in
      Core_unix.unlink key_file;
      Core_unix.unlink (dir ^/ "configs" ^/ follow_id ^ ".sexp");
      let stray = Follows.id ~follower:leader ~leader:owner in
      Out_channel.write_all (dir ^/ "configs" ^/ stray ^ ".sexp") ~data:"()";
      run_api ~sim ~dir ~database_url (fun client ->
        ls (dir ^/ "configs");
        [%expect
          {| (0xee4e2c43a64783bc6a296db26e1b140245a6efc4-0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf.sexp) |}];
        (* The rebuilt key file opens to the same agent key. *)
        let agent_after = Flow.agent_key ~dir ~owner in
        print_s
          [%sexp
            (Address.equal
               (Signing.Private_key.address agent_before)
               (Signing.Private_key.address agent_after)
             : bool)];
        [%expect {| true |}];
        (* Session tokens are stateless, so the old one still works. *)
        let%bind status, follows = C.call client ~token `GET "/follows" in
        let%map _, me = C.call client ~token `GET "/me" in
        print_s
          [%sexp
            (status : int)
            , (List.map (Yojson.Safe.Util.to_list follows) ~f:(C.str "state")
               : string list)
            , (C.str "agent.approved" me : string)];
        [%expect {| (200 (running) true) |}])))
;;
