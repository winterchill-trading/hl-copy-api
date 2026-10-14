# migrations/ (AGENTS.md)

Numbered SQL files (`0001_create_tables.sql` and later). `lib/gen` embeds them into the binary,
and the server applies them at startup under an advisory lock.

- Add a new file with the next number. Never edit a file that has run on any database.
