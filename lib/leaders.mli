(** [GET /leaders] and [GET /leaders/<address>], proxied from [hl-leaderboard serve] and
    reshaped into {!Api_types.Leaders_response} and {!Api_types.Leader_detail}.

    Mapping from the leaderboard's ranking entries:
    - [rank]: the entry's rank; unranked leaders (too few round trips) keep their place in
      the list, numbered after the ranked ones;
    - [score]: the leaderboard score (a return, about [0.] to [1.] for good leaders) times
      100, clamped to [[0, 100]] and rounded to two decimals;
    - [breakdown]: the score components ([avg_hold_hours] becomes seconds, [return] is
      [roi]);
    - [window_pnl]: the leaderboard's [day], [week], [month] and [allTime] pnl;
    - [followers]: follows on this platform that are running or paused;
    - [scoring]: hl-leaderboard's leader-scoring summary, when the ranking has one. When
      every leader has one, [score] is the composite leader-scoring score (0 to 100)
      instead, and the list is ordered and numbered by it: eligible leaders first, best
      first.

    The detail's [scoring] is the leader-scoring report hl-leaderboard serves with the
    leader (metrics, score components, the learned forecast, capacity curve, alerts). *)

open! Core
open Async
open Hl_protocol

(** Pure conversions, exposed for tests. [followers] counts this platform's followers of
    an address. *)
val leaders_of_json
  :  followers:(Address.t -> int)
  -> Yojson.Safe.t
  -> Api_types.Leaders_response.t Or_error.t

val leader_detail_of_json
  :  followers:(Address.t -> int)
  -> Yojson.Safe.t
  -> Api_types.Leader_detail.t Or_error.t

val fill_to_api : User_fill.t -> Api_types.Fill.t
val position_to_api : Clearinghouse_state.Position.t -> Api_types.Position.t

type t

(** [base_url] is where [hl-leaderboard serve] listens, e.g. [http://localhost:8090].
    Responses are cached for [ttl] (default 10 s): the ranking changes when [rank] runs,
    not per request. *)
val create : ?ttl:Time_ns.Span.t -> base_url:Uri.t -> unit -> t

val leaders
  :  t
  -> followers:(Address.t -> int)
  -> Api_types.Leaders_response.t Or_error.t Deferred.t

(** [Ok None] when the leaderboard has nothing for the address. *)
val leader
  :  t
  -> followers:(Address.t -> int)
  -> Address.t
  -> Api_types.Leader_detail.t option Or_error.t Deferred.t
