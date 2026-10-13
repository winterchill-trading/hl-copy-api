(** Counters and gauges in the Prometheus text format, for [GET /metrics].

    Requests are counted as [hl_copy_api_requests_total{route, method, status}] with
    [route] the route pattern (e.g. [/follows/:id]), never the raw path, so a client
    cannot create unbounded label values. *)

open! Core

type t

val create : unit -> t

val request
  :  t
  -> route:string
  -> meth:string
  -> status:int
  -> duration:Time_ns.Span.t
  -> unit

(** [hl_copy_api_<name>_total], e.g. ["logins"], ["agents_approved"]. *)
val incr : t -> string -> unit

(** [hl_copy_api_<name>], read when rendering. *)
val gauge : t -> string -> (unit -> float) -> unit

val render : t -> string
