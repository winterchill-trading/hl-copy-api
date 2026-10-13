open! Core
open! Async

type t = { base_url : Uri.t }

let create ~port = { base_url = Uri.of_string (sprintf "http://127.0.0.1:%d" port) }
let base_url t = t.base_url

let call_raw ?(headers = []) t meth target =
  let uri = Uri.of_string (Uri.to_string t.base_url ^ target) in
  let%bind resp, body =
    Cohttp_async.Client.call ~headers:(Cohttp.Header.of_list headers) meth uri
  in
  let%map body = Cohttp_async.Body.to_string body in
  ( Cohttp.Code.code_of_status (Cohttp.Response.status resp)
  , Cohttp.Response.headers resp
  , body )
;;

let call ?token ?body ?(headers = []) t meth target =
  let uri = Uri.of_string (Uri.to_string t.base_url ^ target) in
  let headers =
    Cohttp.Header.of_list
      (headers
       @ Option.value_map token ~default:[] ~f:(fun token ->
         [ "authorization", "Bearer " ^ token ])
       @ Option.value_map body ~default:[] ~f:(fun _ ->
         [ "content-type", "application/json" ]))
  in
  let body =
    Option.map body ~f:(fun json ->
      Cohttp_async.Body.of_string (Yojson.Safe.to_string json))
  in
  let%bind resp, body = Cohttp_async.Client.call ~headers ?body meth uri in
  let%map body = Cohttp_async.Body.to_string body in
  let json =
    match Yojson.Safe.from_string body with
    | json -> json
    | exception _ -> `Null
  in
  Cohttp.Code.code_of_status (Cohttp.Response.status resp), json
;;

let path p json =
  List.fold (String.split p ~on:'.') ~init:json ~f:(fun json key ->
    match json with
    | `Assoc fields ->
      List.Assoc.find fields key ~equal:String.equal |> Option.value ~default:`Null
    | _ -> `Null)
;;

let str p json =
  match path p json with
  | `String s -> s
  | json -> Yojson.Safe.to_string json
;;
