open! Core

module Bucket = struct
  type t =
    { mutable tokens : float
    ; mutable last : Time_ns.t
    }
end

type t =
  { per_ns : float
  ; burst : float
  ; buckets : Bucket.t String.Table.t
  }

let create ~per_minute ~burst =
  { per_ns = Float.of_int per_minute /. 60e9
  ; burst = Float.of_int burst
  ; buckets = String.Table.create ()
  }
;;

let tracked t = Hashtbl.length t.buckets
let max_keys = 10_000

let refill t (b : Bucket.t) ~now =
  let elapsed = Float.of_int (Time_ns.Span.to_int_ns (Time_ns.diff now b.last)) in
  b.tokens <- Float.min t.burst (b.tokens +. (Float.max 0. elapsed *. t.per_ns));
  b.last <- now
;;

let allow t ~key ~now =
  if Hashtbl.length t.buckets > max_keys
  then
    Hashtbl.filter_inplace t.buckets ~f:(fun b ->
      refill t b ~now;
      Float.( < ) b.tokens t.burst);
  let bucket =
    Hashtbl.find_or_add t.buckets key ~default:(fun () ->
      { Bucket.tokens = t.burst; last = now })
  in
  refill t bucket ~now;
  if Float.( >= ) bucket.tokens 1.
  then (
    bucket.tokens <- bucket.tokens -. 1.;
    true)
  else false
;;
