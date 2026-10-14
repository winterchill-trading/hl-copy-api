(** Follows: which leader a user copies, how, and whether the copy is running.

    Each follow is a {!Follow_record.t} in the {!Store} (kept after a stop so the
    dashboard can show it) and, while it is running or paused, the
    {!Hl_copy_core.Follower_config.t} file the engine watches:
    [<config_dir>/<follower>-<leader>.sexp] ([paused true] when paused). Stopping a follow
    removes the file, which stops the engine's follower. The store is written first and is
    the record of truth; {!sync_configs} rewrites the directory from it at startup.

    The id is ["<follower>-<leader>"], the config file's name without [.sexp]: a user
    follows a given leader at most once. Files are written to a dot-prefixed temporary
    name and renamed into place, so the engine never reads half a config. *)

open! Core
open! Async
open Hl_protocol
module Record = Follow_record

type t

val create : store:Store.t -> config_dir:string -> t
val config_dir : t -> string
val id : follower:Address.t -> leader:Address.t -> string

(** The engine's config for a record. Web caps of [0.] mean "no cap" and an empty
    allowlist means every coin. Fails when {!Hl_copy_core.Follower_config.validate} does. *)
val follower_config : Record.t -> Hl_copy_core.Follower_config.t Or_error.t

(** Starts following [leader]. Following a leader again after a stop restarts that follow
    with the new settings; following one that is running or paused fails. *)
val start
  :  t
  -> follower:Address.t
  -> leader:Address.t
  -> scale:Api_types.Scale_mode.t
  -> caps:Api_types.Caps.t
  -> now_ms:int
  -> Record.t Or_error.t Deferred.t

(** The follow [id] of [follower]; another user's follows are not found. *)
val find : t -> follower:Address.t -> string -> Record.t option Or_error.t Deferred.t

(** [follower]'s follows, oldest first. *)
val list : t -> follower:Address.t -> Record.t list Or_error.t Deferred.t

(** Every follow of every user, for the engine-facing views. *)
val all : t -> Record.t list Or_error.t Deferred.t

(** Changes settings and/or state. A stopped follow cannot be changed, only started again
    with {!start}. *)
val update
  :  t
  -> follower:Address.t
  -> string
  -> ?scale:Api_types.Scale_mode.t
  -> ?caps:Api_types.Caps.t
  -> ?state:Api_types.Follow_state.t
  -> now_ms:int
  -> unit
  -> Record.t Or_error.t Deferred.t

(** Makes [config_dir] match the store: writes the config of every running or paused
    follow (unless the file already says the same) and removes follow config files with no
    such follow behind them. *)
val sync_configs : t -> unit Or_error.t Deferred.t

(** Copies the records of an older version, which kept one [<id>.sexp] per follow in
    [dir], into the store; records already there win. Returns how many were added. *)
val import_records : t -> dir:string -> int Or_error.t Deferred.t
