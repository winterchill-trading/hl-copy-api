open! Core
open Async
open Hl_protocol

module Follow_status = struct
  type t =
    { follower : Address.t
    ; leader : Address.t
    ; state : string option
    ; pnl : float
    ; positions : Api_types.Position.t list
    ; last_error : string option
    }
  [@@deriving sexp_of]
end

type t = Follow_status.t list [@@deriving sexp_of]

let empty = []

let member key = function
  | `Assoc fields -> List.Assoc.find fields key ~equal:String.equal
  | _ -> None
;;

let num = function
  | Some (`Float f) -> f
  | Some (`Int i) -> Float.of_int i
  | Some (`Intlit s) | Some (`String s) ->
    Float.of_string_opt s |> Option.value ~default:0.
  | _ -> 0.
;;

let str = function
  | Some (`String s) -> Some s
  | _ -> None
;;

let address json key =
  match str (member key json) with
  | Some s
    when String.length s = 42
         && String.is_prefix s ~prefix:"0x"
         && String.for_all (String.drop_prefix s 2) ~f:Char.is_hex_digit ->
    Some (Address.of_string s)
  | _ -> None
;;

let position json : Api_types.Position.t option =
  Option.map
    (str (member "coin" json))
    ~f:(fun coin ->
      { Api_types.Position.coin
      ; size = num (member "size" json)
      ; entry_px = num (member "entry_px" json)
      ; unrealized_pnl = num (member "unrealized_pnl" json)
      ; leverage = num (member "leverage" json)
      })
;;

let follow json : Follow_status.t option =
  match address json "follower", address json "leader" with
  | Some follower, Some leader ->
    Some
      { follower
      ; leader
      ; state = str (member "state" json)
      ; pnl = num (member "pnl" json)
      ; positions =
          (match member "positions" json with
           | Some (`List l) -> List.filter_map l ~f:position
           | _ -> [])
      ; last_error = str (member "last_error" json)
      }
  | _ -> None
;;

let of_json json =
  match member "followers" json with
  | Some (`List l) -> List.filter_map l ~f:follow
  | _ -> empty
;;

let find t ~follower ~leader =
  List.find t ~f:(fun (s : Follow_status.t) ->
    Address.equal s.follower follower && Address.equal s.leader leader)
;;

let fetch ?(timeout = Time_ns.Span.of_sec 2.) base_url =
  match base_url with
  | None -> return empty
  | Some base_url ->
    (match%map
       Clock_ns.with_timeout
         timeout
         (Hl_client.Http.get (Uri.with_path base_url "/status"))
     with
     | `Result (Ok { status = 200; body }) ->
       (match Yojson.Safe.from_string body with
        | json -> of_json json
        | exception _ -> empty)
     | `Result (Ok _ | Error _) | `Timeout -> empty)
;;
