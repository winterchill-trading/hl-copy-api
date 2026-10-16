(** A follow's execution algorithm as the API takes it: execution-algos' short form
    ([Execution_algos.Algo.of_string]: ["immediate"], ["twap:60s:6"], ["vwap:5m"],
    ["pov:0.1"], ["passive:30s"], ["iceberg:0.25:30s"], ["adaptive:20s"], or a sexp of the
    type), parsed and validated by execution-algos itself, stored in its canonical short
    form, and handed to the engine as {!Hl_copy_core.Exec_algo.t} (the same variant). *)

open! Core

(** The canonical short form, [None] for immediate. Errors on anything execution-algos
    cannot parse or rejects ([Algo.validate]: non-positive durations, rates above 1, ...). *)
val parse : string -> string option Or_error.t

(** The engine's value for a stored form ([None] is [Immediate]). *)
val to_exec_algo : string option -> Hl_copy_core.Exec_algo.t Or_error.t
