open! Core
open! Async
open Pg_async

let counter = ref 0

let fresh_name () =
  incr counter;
  sprintf
    "hl_copy_test_%d_%d_%s"
    (Core_unix.getpid () |> Pid.to_int)
    !counter
    (String.lowercase (Hl_copy_api.Hex.random 4))
;;

let on_server admin_url =
  let name = fresh_name () in
  let%bind conn =
    Config.of_url admin_url |> Or_error.ok_exn |> Connection.connect >>| Pg_error.ok_exn
  in
  (* Database names cannot be parameters; [name] is generated above. *)
  let%bind created = Query.execute conn (sprintf "CREATE DATABASE %s" name) in
  let%map () = Connection.close conn in
  ignore (Pg_error.ok_exn created : int);
  Uri.with_path (Uri.of_string admin_url) ("/" ^ name) |> Uri.to_string
;;

let on_temp_cluster () =
  let%bind cluster = Pg_test.shared () in
  let%map config = Pg_test.create_database cluster in
  sprintf
    "postgres://postgres@127.0.0.1:%d/%s?sslmode=disable"
    (Pg_test.port cluster)
    (Option.value_exn config.dbname)
;;

let fresh_url () =
  match Sys.getenv "HL_COPY_TEST_DATABASE_URL" with
  | Some url when not (String.is_empty url) -> on_server url
  | Some _ | None -> on_temp_cluster ()
;;
