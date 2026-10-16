open! Core
module Algo = Execution_algos.Algo

let of_string s =
  let open Or_error.Let_syntax in
  let%bind algo = Algo.of_string (String.strip s) in
  let%map () = Algo.validate algo in
  algo
;;

let parse s =
  Or_error.map (of_string s) ~f:(function
    | Immediate -> None
    | algo -> Some (Algo.to_string algo))
  |> Or_error.tag ~tag:"invalid execution algorithm"
;;

(* hl-copy-core keeps a copy of execution-algos' type (so it does not depend on it); the
   two stable sexps are the same, which the tests check for every constructor. *)
let to_exec_algo = function
  | None -> Ok Hl_copy_core.Exec_algo.Immediate
  | Some s ->
    let open Or_error.Let_syntax in
    let%bind algo = of_string s in
    Or_error.try_with (fun () ->
      Hl_copy_core.Exec_algo.Stable.V1.t_of_sexp (Algo.Stable.V1.sexp_of_t algo))
;;
