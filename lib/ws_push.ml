open! Core

type t =
  | Me of Api_types.Me.t
  | Follow of Api_types.Follow.t
  | Fill of Api_types.Fill.t
  | Error of string
[@@deriving sexp_of]

let to_json = function
  | Me me -> `Assoc [ "type", `String "me"; "me", Api_types.Me.yojson_of_t me ]
  | Follow f ->
    `Assoc [ "type", `String "follow"; "follow", Api_types.Follow.yojson_of_t f ]
  | Fill f -> `Assoc [ "type", `String "fill"; "fill", Api_types.Fill.yojson_of_t f ]
  | Error e -> `Assoc [ "type", `String "error"; "error", `String e ]
;;

let to_string t = Yojson.Safe.to_string (to_json t)
