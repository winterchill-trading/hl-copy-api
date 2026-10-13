(** A minimal HTTP client for driving the API in tests. *)

open! Core
open! Async

type t

val create : port:int -> t
val base_url : t -> Uri.t

(** Status code and parsed JSON body ([`Null] when empty or not JSON). *)
val call
  :  ?token:string
  -> ?body:Yojson.Safe.t
  -> ?headers:(string * string) list
  -> t
  -> Cohttp.Code.meth
  -> string
  -> (int * Yojson.Safe.t) Deferred.t

(** Raw response headers and body text, for [/metrics] and CORS checks. *)
val call_raw
  :  ?headers:(string * string) list
  -> t
  -> Cohttp.Code.meth
  -> string
  -> (int * Cohttp.Header.t * string) Deferred.t

(** [member "a.b.c" json] *)
val path : string -> Yojson.Safe.t -> Yojson.Safe.t

val str : string -> Yojson.Safe.t -> string
