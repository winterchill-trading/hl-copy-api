(** Fresh PostgreSQL databases for tests.

    With [HL_COPY_TEST_DATABASE_URL] set (CI's Postgres service, a superuser URL), each
    call creates a new database on that server. Otherwise pg-async's throwaway cluster
    ([initdb] + [pg_ctl], one per test process) is used, which needs the PostgreSQL server
    binaries installed. *)

open! Core
open! Async

(** The URL of a new, empty database. *)
val fresh_url : unit -> string Deferred.t
