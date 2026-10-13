open! Core
open Hl_protocol

module Status = struct
  type t =
    | Pending
    | Active
    | Revoked
  [@@deriving sexp, compare, equal, enumerate]
end

module Entry = struct
  type t =
    { owner : Address.t
    ; agent_address : Address.t
    ; agent_name : string
    ; nonce : int
    ; created_ms : int
    ; valid_until_ms : int option
    ; status : Status.t
    ; sealed_key : string
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { dir : string
  ; key : Sealed.Master_key.t
  }

let create ~dir key = { dir; key }
let dir t = t.dir
let suffix = ".sexp"
let path t ~owner = t.dir ^/ Address.to_string owner ^ suffix

let entries t ~owner =
  let path = path t ~owner in
  match Sys_unix.file_exists path with
  | `No | `Unknown -> Ok []
  | `Yes ->
    Or_error.try_with (fun () -> Sexp.load_sexps_conv_exn path Entry.t_of_sexp)
    |> Or_error.tag ~tag:path
;;

let owners t =
  match Sys_unix.readdir t.dir with
  | exception _ -> []
  | files ->
    Array.to_list files
    |> List.filter_map ~f:(fun file ->
      Option.map (String.chop_suffix file ~suffix) ~f:Address.of_string)
    |> List.sort ~compare:Address.compare
;;

let write t ~owner entries =
  Or_error.try_with (fun () ->
    Core_unix.mkdir_p ~perm:0o700 t.dir;
    let path = path t ~owner in
    let tmp = path ^ ".tmp" in
    Out_channel.with_file tmp ~perm:0o600 ~f:(fun oc ->
      List.iter entries ~f:(fun entry ->
        Out_channel.output_string oc (Sexp.to_string_mach (Entry.sexp_of_t entry));
        Out_channel.newline oc));
    Core_unix.rename ~src:tmp ~dst:path)
;;

let aad ~owner ~agent_address =
  Address.to_string owner ^ "/" ^ Address.to_string agent_address
;;

let add_pending
  t
  ~owner
  ~agent_address
  ~agent_name
  ~nonce
  ~created_ms
  ~valid_until_ms
  ~secret
  =
  let open Or_error.Let_syntax in
  let%bind existing = entries t ~owner in
  if List.exists existing ~f:(fun e -> Address.equal e.agent_address agent_address)
  then
    Or_error.error_s
      [%message "agent address was already issued" (agent_address : Address.t)]
  else (
    let entry =
      { Entry.owner
      ; agent_address
      ; agent_name
      ; nonce
      ; created_ms
      ; valid_until_ms
      ; status = Pending
      ; sealed_key =
          Sealed.to_hex (Sealed.seal t.key ~aad:(aad ~owner ~agent_address) secret)
      }
    in
    let%map () = write t ~owner (entry :: existing) in
    entry)
;;

let update t ~owner ~agent_address ~f =
  let open Or_error.Let_syntax in
  let%bind existing = entries t ~owner in
  match List.find existing ~f:(fun e -> Address.equal e.agent_address agent_address) with
  | None -> Or_error.error_s [%message "unknown agent" (agent_address : Address.t)]
  | Some _ ->
    let updated = List.map existing ~f in
    let%map () = write t ~owner updated in
    List.find_exn updated ~f:(fun e -> Address.equal e.agent_address agent_address)
;;

let activate t ~owner ~agent_address =
  update t ~owner ~agent_address ~f:(fun e ->
    if Address.equal e.agent_address agent_address
    then { e with status = Active }
    else (
      match e.status with
      | Active -> { e with status = Revoked }
      | Pending | Revoked -> e))
;;

let revoke t ~owner ~agent_address =
  update t ~owner ~agent_address ~f:(fun e ->
    if Address.equal e.agent_address agent_address then { e with status = Revoked } else e)
;;

let find t ~owner ~agent_address =
  Or_error.map (entries t ~owner) ~f:(fun entries ->
    List.find entries ~f:(fun e -> Address.equal e.agent_address agent_address))
;;

let first_with t ~owner status =
  Or_error.map (entries t ~owner) ~f:(fun entries ->
    List.find entries ~f:(fun e -> Status.equal e.status status))
;;

let active t ~owner = first_with t ~owner Active
let latest_pending t ~owner = first_with t ~owner Pending

let secret t (entry : Entry.t) =
  let open Or_error.Let_syntax in
  let%bind box = Sealed.of_hex entry.sealed_key in
  Sealed.open_ t.key ~aad:(aad ~owner:entry.owner ~agent_address:entry.agent_address) box
  |> Or_error.tag_s ~tag:[%message "agent key" ~agent:(entry.agent_address : Address.t)]
;;
