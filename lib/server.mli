(** The HTTP and websocket server.

    Routes (JSON bodies are {!Api_types}; [auth] means [Authorization: Bearer <token>]):

    {v
GET    /healthz                        liveness, no auth, not rate limited
GET    /metrics                        Prometheus text
POST   /auth/challenge                 Auth.Challenge_request -> Auth.Challenge
POST   /auth/verify                    Auth.Verify_request (nonce optional) -> Auth.Session
POST   /agent/new              auth    -> Agent_offer (+ "typed_data" for both actions)
POST   /agent/approved         auth    Agent_approval (approve_agent optional) -> Agent_status
POST   /agent/revoke           auth    -> Agent_status
POST   /builder-fee            auth    Builder_fee_approval (action optional) -> Agent_status
GET    /follows                auth    -> Follow list
POST   /follows                auth    Follow_request -> Follow (201); needs an active agent
GET    /follows/:id            auth    -> Follow
PATCH  /follows/:id            auth    Follow_update (+ optional scale, caps) -> Follow
DELETE /follows/:id            auth    -> Follow (stopped)
POST   /follows/:id/pause|resume|stop  auth -> Follow
GET    /leaders                        -> Leaders_response
GET    /leaders/:address               -> Leader_detail
GET    /me                     auth    -> Me
GET    /ws?token=<token>               websocket, see {!Api_types.Ws_push}
    v}

    Errors are {!Api_types.Api_error} with 400 (bad body), 401 (no or bad session), 404,
    409 (state conflict), 413 (body over 64 KiB), 429 (rate limited), 502 (exchange or
    leaderboard failure) or 503 (no leaderboard configured, or the store failed).

    Every response carries CORS headers for the configured origins, and [OPTIONS] answers
    preflight requests. Each request is logged (method, route, status, milliseconds,
    client) at [Info]. *)

open! Core
open! Async

module Config : sig
  type t =
    { exchange_url : Uri.t (** hl-sim or testnet; mainnet is refused *)
    ; leaderboard_url : Uri.t option (** [hl-leaderboard serve] *)
    ; engine_url : Uri.t option (** hl-copy-engine, for [/status] *)
    ; state_dir : string
    (** [agents/], the {!Hl_copy_core.Key_store} files the engine reads (written from the
        store); an older version's [follows/] records are imported once *)
    ; config_dir : string (** follower configs the engine watches *)
    ; public_url : Uri.t (** this API as browsers reach it; the sign-in domain and URI *)
    ; allowed_origins : string list (** CORS; ["*"] allows any origin *)
    ; builder : Agents.Builder.t option
    ; session_ttl : Time_ns.Span.t
    ; requests_per_minute : int (** per client IP, every route but [/healthz] *)
    ; auth_requests_per_minute : int (** per client IP, [/auth/*] *)
    ; ws_status_interval : Time_ns.Span.t (** how often [/ws] pushes [me] *)
    }
  [@@deriving sexp_of]

  (** hl-sim on [localhost:3000], no leaderboard or engine, [./state] and
      [./state/configs], public URL [http://localhost:8080], origins
      [http://localhost:8000] (the web dev server), no builder, 24 h sessions, 600 and 30
      requests per minute, 15 s status pushes. *)
  val default : t
end

type t

(** Imports an older version's state files into [store] (once per state directory), then
    makes the engine's files (key files, follower configs) match the store. *)
val create
  :  Config.t
  -> master_key:Hl_copy_core.Key_store.Master_key.t
  -> store:Store.t
  -> t Or_error.t Deferred.t

val config : t -> Config.t
val metrics : t -> Metrics.t
val agents : t -> Agents.t
val follows : t -> Follows.t
val store : t -> Store.t

(** [port] 0 picks a free port. *)
val start : t -> port:int -> (Socket.Address.Inet.t, int) Cohttp_async.Server.t Deferred.t

(** Closes websocket clients and the fill feed. *)
val close : t -> unit Deferred.t
