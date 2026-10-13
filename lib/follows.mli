(** Follows: which leader a user copies, how, and whether the copy is running.

    Each follow is two files:

    - [<state_dir>/<id>.sexp]: the API's own {!Record.t} (the web form's scale mode and
      caps, state, timestamps), kept after a stop so the dashboard can show it;
    - [<config_dir>/<follower>-<leader>.sexp]: the {!Hl_copy_core.Follower_config.t} the
      engine watches. It exists while the follow is running or paused ([paused true]) and
      is removed when the follow stops, which stops the engine's follower.

    The id is ["<follower>-<leader>"], the config file's name without [.sexp]: a user
    follows a given leader at most once. Files are written to a dot-prefixed temporary
    name and renamed into place, so the engine never reads half a config. *)

open! Core
open Hl_protocol

module Record : sig
  type t =
    { id : string
    ; follower : Address.t
    ; leader : Address.t
    ; scale : Api_types.Scale_mode.t
    ; caps : Api_types.Caps.t
    ; state : Api_types.Follow_state.t
    ; created_ms : int
    ; updated_ms : int
    }
  [@@deriving sexp, compare, equal]
end

type t

val create : config_dir:string -> state_dir:string -> t
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
  -> Record.t Or_error.t

(** The follow [id] of [follower]; another user's follows are not found. *)
val find : t -> follower:Address.t -> string -> Record.t option

(** [follower]'s follows, oldest first. *)
val list : t -> follower:Address.t -> Record.t list

(** Every follow of every user, for the engine-facing views. *)
val all : t -> Record.t list

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
  -> Record.t Or_error.t
