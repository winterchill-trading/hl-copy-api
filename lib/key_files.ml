open! Core
open Hl_protocol
module Key_store = Hl_copy_core.Key_store

let write key_store ~account entry =
  Or_error.try_with (fun () ->
    let path = Key_store.path key_store ~account in
    let dir = Filename.dirname path in
    Core_unix.mkdir_p ~perm:0o700 dir;
    let tmp = dir ^/ "." ^ Address.to_string account ^ ".tmp" in
    Out_channel.with_file tmp ~perm:0o600 ~f:(fun oc ->
      Out_channel.output_string
        oc
        (Sexp.to_string_hum (Key_store.Entry.sexp_of_t entry) ^ "\n"));
    Core_unix.rename ~src:tmp ~dst:path)
  |> Or_error.tag ~tag:"writing agent key file"
;;
