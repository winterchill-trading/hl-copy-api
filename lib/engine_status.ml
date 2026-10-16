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
    ; execution : Api_types.Execution.t option
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

let int = function
  | Some (`Int i) -> i
  | Some (`Float f) -> Float.iround_towards_zero_exn f
  | _ -> 0
;;

let list = function
  | Some (`List l) -> l
  | _ -> []
;;

(* The engine writes report times as ISO 8601 ([2026-10-16T01:02:03.250000000Z]). *)
let time_ms s =
  Option.try_with (fun () ->
    Float.of_int
      (Time_ns.to_int_ns_since_epoch (Time_ns.of_string_with_utc_offset s) / 1_000_000))
;;

let report json : Api_types.Execution_report.t =
  { time = Option.bind (str (member "time" json)) ~f:time_ms
  ; algo = Option.value (str (member "algo" json)) ~default:""
  ; outcome = Option.value (str (member "outcome" json)) ~default:""
  ; side =
      (match str (member "side" json) with
       | Some "sell" -> Sell
       | _ -> Buy)
  ; target = num (member "target" json)
  ; filled = num (member "filled" json)
  ; avg_px = num (member "avg_px" json)
  ; arrival_px = num (member "arrival_px" json)
  ; children = int (member "children" json)
  ; fees = num (member "fees" json)
  ; arrival_slippage_bps = num (member "arrival_slippage_bps" json)
  ; shortfall_bps = num (member "shortfall_bps" json)
  }
;;

(* [execution] in a follower's status: the algorithm, the parents being worked, the last
   finished ones and their totals (hl-copy-engine's [Follower.status_json]). *)
let execution json : Api_types.Execution.t option =
  match member "execution" json with
  | Some (`Assoc _ as e) ->
    let totals = Option.value (member "totals" e) ~default:(`Assoc []) in
    Some
      { algo = Option.value (str (member "algo" e)) ~default:"immediate"
      ; parents = int (member "parents" totals)
      ; filled_parents = int (member "filled_parents" totals)
      ; fill_rate = num (member "fill_rate" totals)
      ; shortfall_bps = num (member "shortfall_bps" totals)
      ; slippage_bps = num (member "slippage_bps" totals)
      ; fees = num (member "fees" totals)
      ; active = List.length (list (member "active" e))
      ; (* the engine lists the oldest first *)
        recent = List.rev_map (list (member "recent" e)) ~f:report
      }
  | _ -> None
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
      ; execution = execution json
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
