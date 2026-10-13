(** Token buckets keyed by client (IP address, or wallet address for authenticated
    routes): [burst] requests at once, refilled at [per_minute]. *)

open! Core

type t

val create : per_minute:int -> burst:int -> t

(** Takes a token from [key]'s bucket; [false] when it is empty. Buckets that have
    refilled completely are forgotten once more than 10_000 keys are tracked. *)
val allow : t -> key:string -> now:Time_ns.t -> bool

val tracked : t -> int
