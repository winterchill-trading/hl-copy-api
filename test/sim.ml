open! Core
open! Async

type t =
  { server : Hl_sim.Server.t
  ; base_url : Uri.t
  ; close : unit -> unit Deferred.t
  }

let start () =
  Log.Global.set_output [];
  let server =
    Hl_sim.Server.create
      ~config:{ Hl_sim.Server.Config.default with strict_signatures = true }
      (Hl_sim.Adapt.create_exchange ())
  in
  let%map http = Hl_sim.Server.listen server ~port:0 in
  { server
  ; base_url = Uri.of_string (sprintf "http://127.0.0.1:%d" (Hl_sim.Server.port http))
  ; close = (fun () -> Cohttp_async.Server.close http)
  }
;;

let with_sim f =
  let%bind t = start () in
  Monitor.protect (fun () -> f t) ~finally:t.close
;;

(* Keys are derived from a counter so each test's wallets are distinct and reproducible;
   none of them ever holds funds outside the simulator. *)
let wallet_key n =
  Hl_client.Signing.Private_key.of_hex (sprintf "%064x" (0x1000 + n)) |> Or_error.ok_exn
;;

let with_dir f =
  let dir = Filename_unix.temp_dir "hl-copy-api" "" in
  Monitor.protect
    (fun () -> f dir)
    ~finally:(fun () ->
      let%map (_ : Core_unix.Exit_or_signal.t) =
        Unix.system (sprintf "rm -rf %s" (Filename.quote dir))
      in
      ())
;;
