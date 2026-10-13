open! Core

module Key = struct
  type t = string * string * int [@@deriving compare, hash, sexp]
end

type t =
  { requests : int Hashtbl.M(Key).t
  ; seconds : float Hashtbl.M(Key).t
  ; counters : int String.Table.t
  ; gauges : (unit -> float) String.Table.t
  }

let create () =
  { requests = Hashtbl.create (module Key)
  ; seconds = Hashtbl.create (module Key)
  ; counters = String.Table.create ()
  ; gauges = String.Table.create ()
  }
;;

let request t ~route ~meth ~status ~duration =
  let key = route, meth, status in
  Hashtbl.incr t.requests key;
  Hashtbl.update t.seconds key ~f:(fun s ->
    Option.value s ~default:0. +. Time_ns.Span.to_sec duration)
;;

let incr t name = Hashtbl.incr t.counters name
let gauge t name f = Hashtbl.set t.gauges ~key:name ~data:f

let render t =
  let buf = Buffer.create 1024 in
  let line fmt = Printf.bprintf buf (fmt ^^ "\n") in
  let labels (route, meth, status) =
    sprintf "route=%S,method=%S,status=\"%d\"" route meth status
  in
  line "# TYPE hl_copy_api_requests_total counter";
  List.iter
    (Hashtbl.to_alist t.requests |> List.sort ~compare:[%compare: Key.t * int])
    ~f:(fun (key, n) -> line "hl_copy_api_requests_total{%s} %d" (labels key) n);
  line "# TYPE hl_copy_api_request_seconds_sum counter";
  List.iter
    (Hashtbl.to_alist t.seconds |> List.sort ~compare:[%compare: Key.t * float])
    ~f:(fun (key, s) -> line "hl_copy_api_request_seconds_sum{%s} %.6f" (labels key) s);
  List.iter
    (Hashtbl.to_alist t.counters |> List.sort ~compare:[%compare: string * int])
    ~f:(fun (name, n) ->
      line "# TYPE hl_copy_api_%s_total counter" name;
      line "hl_copy_api_%s_total %d" name n);
  List.iter
    (Hashtbl.keys t.gauges |> List.sort ~compare:String.compare)
    ~f:(fun name ->
      line "# TYPE hl_copy_api_%s gauge" name;
      line "hl_copy_api_%s %g" name ((Hashtbl.find_exn t.gauges name) ()));
  Buffer.contents buf
;;
