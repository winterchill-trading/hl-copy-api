open! Core
open Async
open Hl_protocol

let member key json =
  match json with
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

let int = function
  | Some (`Int i) -> Some i
  | Some (`Float f) -> Some (Float.iround_towards_zero_exn f)
  | _ -> None
;;

let str = function
  | Some (`String s) -> Some s
  | _ -> None
;;

let address_to_api a = Api_types.Address.of_string (Address.to_string a)

let ms_of_iso s =
  match Time_ns.of_string_with_utc_offset s with
  | t -> Float.of_int (Time_ns.to_int_ns_since_epoch t / 1_000_000)
  | exception _ -> 0.
;;

let leader_of_entry ~followers ~position entry : Api_types.Leader.t Or_error.t =
  match str (member "address" entry) with
  | None -> Or_error.error_string "leaderboard entry without an address"
  | Some address ->
    let address = Address.of_string address in
    let c = Option.value (member "components" entry) ~default:(`Assoc []) in
    let window name =
      num
        (Option.bind (member "leaderboard" entry) ~f:(member name)
         |> Option.bind ~f:(member "pnl"))
    in
    Ok
      { address = address_to_api address
      ; display_name = str (member "display_name" entry)
      ; rank = Option.value (int (member "rank" entry)) ~default:position
      ; score =
          Float.clamp_exn (num (member "score" entry) *. 100.) ~min:0. ~max:100.
          |> Float.round_decimal ~decimal_digits:2
      ; breakdown =
          { pnl = num (member "pnl" c)
          ; roi = num (member "return" c)
          ; max_drawdown = num (member "max_drawdown" c)
          ; win_rate = num (member "win_rate" c)
          ; trade_count = Option.value (int (member "trade_count" c)) ~default:0
          ; avg_hold_secs = num (member "avg_hold_hours" c) *. 3600.
          ; consistency = num (member "consistency" c)
          }
      ; account_value = num (member "account_value" entry)
      ; window_pnl =
          { day = window "day"
          ; week = window "week"
          ; month = window "month"
          ; all_time = window "allTime"
          }
      ; followers = followers address
      }
;;

let leaders_of_json ~followers json =
  match member "leaders" json with
  | Some (`List entries) ->
    let ranked =
      List.count entries ~f:(fun e -> Option.is_some (int (member "rank" e)))
    in
    let%map.Or_error leaders =
      List.mapi entries ~f:(fun i entry ->
        (* Unranked entries come after the ranked ones in the file. *)
        leader_of_entry ~followers ~position:(Int.max (ranked + 1) (i + 1)) entry)
      |> Or_error.combine_errors
    in
    { Api_types.Leaders_response.as_of =
        Option.value_map (str (member "generated_at" json)) ~default:0. ~f:ms_of_iso
    ; leaders
    }
  | _ -> Or_error.error_string "leaderboard response without a leaders list"
;;

let to_f = Float.of_string

let fill_to_api (f : User_fill.t) : Api_types.Fill.t =
  { time = Float.of_int f.time
  ; coin = Coin.to_string f.coin
  ; side =
      (match f.side with
       | Buy -> Buy
       | Sell -> Sell)
  ; px = to_f (Price.to_string f.px)
  ; sz = to_f (Size.to_string f.sz)
  ; closed_pnl = to_f (Usd.to_string f.closed_pnl)
  ; fee = to_f (Usd.to_string f.fee)
  ; dir = f.dir
  }
;;

let position_to_api (p : Clearinghouse_state.Position.t) : Api_types.Position.t =
  { coin = Coin.to_string p.coin
  ; size = to_f (Size.to_string p.szi)
  ; entry_px =
      Option.value_map p.entry_px ~default:0. ~f:(fun px -> to_f (Price.to_string px))
  ; unrealized_pnl = to_f (Usd.to_string p.unrealized_pnl)
  ; leverage = Float.of_int (Clearinghouse_state.Leverage.value p.leverage)
  }
;;

let list_of key json =
  match member key json with
  | Some (`List l) -> l
  | _ -> []
;;

let leader_detail_of_json ~followers json =
  let open Or_error.Let_syntax in
  let%bind address =
    match str (member "address" json) with
    | Some a -> Ok (Address.of_string a)
    | None -> Or_error.error_string "leader response without an address"
  in
  let%bind leader =
    match member "entry" json with
    | Some (`Assoc _ as entry) -> leader_of_entry ~followers ~position:0 entry
    | _ ->
      leader_of_entry
        ~followers
        ~position:0
        (`Assoc [ "address", `String (Address.to_string address) ])
  in
  let%bind fills =
    Or_error.try_with (fun () ->
      List.map (list_of "fills" json) ~f:(fun j -> fill_to_api (User_fill.t_of_yojson j)))
  in
  let%bind positions =
    Or_error.try_with (fun () ->
      List.map (list_of "positions" json) ~f:(fun j ->
        position_to_api (Clearinghouse_state.Position.t_of_yojson j)))
  in
  let equity_curve =
    List.filter_map (list_of "equity_curve" json) ~f:(function
      | `List [ time; equity ] ->
        Some { Api_types.Equity_point.time = num (Some time); equity = num (Some equity) }
      | _ -> None)
  in
  return { Api_types.Leader_detail.leader; equity_curve; fills; positions }
;;

type t =
  { base_url : Uri.t
  ; ttl : Time_ns.Span.t
  ; cache : (Time_ns.t * Hl_client.Http.Response.t) String.Table.t
  }

let create ?(ttl = Time_ns.Span.of_sec 10.) ~base_url () =
  { base_url; ttl; cache = String.Table.create () }
;;

let get t path =
  let now = Time_ns.now () in
  match Hashtbl.find t.cache path with
  | Some (at, response) when Time_ns.Span.( < ) (Time_ns.diff now at) t.ttl ->
    return (Ok response)
  | _ ->
    let uri = Uri.with_path t.base_url path in
    (match%map Hl_client.Http.get uri with
     | Ok response as ok ->
       if response.status = 200 then Hashtbl.set t.cache ~key:path ~data:(now, response);
       ok
     | Error _ as e -> Or_error.tag e ~tag:"leaderboard unavailable")
;;

let parse (response : Hl_client.Http.Response.t) =
  Or_error.try_with (fun () -> Yojson.Safe.from_string response.body)
;;

let leaders t ~followers =
  match%map get t "/leaders" with
  | Error _ as e -> e
  | Ok response when response.status <> 200 ->
    Or_error.error_s [%message "leaderboard error" (response.status : int)]
  | Ok response -> Or_error.bind (parse response) ~f:(leaders_of_json ~followers)
;;

let leader t ~followers address =
  match%map get t ("/leaders/" ^ Address.to_string address) with
  | Error _ as e -> e
  | Ok { status = 404; _ } -> Ok None
  | Ok response when response.status <> 200 ->
    Or_error.error_s [%message "leaderboard error" (response.status : int)]
  | Ok response ->
    Or_error.bind (parse response) ~f:(leader_detail_of_json ~followers)
    |> Or_error.map ~f:Option.some
;;
