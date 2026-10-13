(** Authenticated encryption of small secrets (agent private keys) under a master key.

    The switch has cryptokit 1.16, which has ChaCha20 and HMAC-SHA256 but no AEAD mode
    (AES-GCM and ChaCha20-Poly1305 arrived in later releases). This module builds the
    standard encrypt-then-MAC composition from those two primitives:

    + Two subkeys are derived from the 32-byte master key with HMAC-SHA256 under fixed
      labels, one for encryption and one for authentication, so the master key itself
      never keys a cipher.
    + Each [seal] draws a fresh 24-byte random salt. The ChaCha20 key for that message is
      [HMAC-SHA256(enc_key, salt)] (an extended-nonce construction in the spirit of
      XChaCha20: a random 24-byte salt never repeats in practice, so no key/nonce pair is
      ever reused, which the 8-byte nonce of cryptokit's ChaCha20 could not promise).
    + The tag is [HMAC-SHA256(mac_key, version || salt || len(aad) || aad || ciphertext)],
      checked in constant time before anything is decrypted.

    Layout: [0x01 || salt (24) || ciphertext || tag (32)].

    TODO: switch to ChaCha20-Poly1305 or AES-GCM (version byte [0x02]) once the switch
    carries a cryptokit with AEAD; [open_] would keep reading version 1. *)

open! Core

module Master_key : sig
  (** Never shown by [sexp_of_t]. *)
  type t [@@deriving sexp_of]

  (** Exactly 64 hex digits (32 bytes), with or without [0x]; e.g. the output of
      [openssl rand -hex 32]. *)
  val of_hex : string -> t Or_error.t

  (** Reads [var] (default [HL_COPY_MASTER_KEY]). *)
  val of_env : ?var:string -> unit -> t Or_error.t
end

(** Random bytes from the operating system's generator. *)
val random_bytes : int -> string

(** [seal key ~aad plaintext]. [aad] (associated data, e.g. the owner and agent addresses)
    is authenticated but not encrypted: opening with another [aad] fails, so a sealed key
    cannot be moved to another account's record. [salt] is for tests only. *)
val seal : ?salt:string -> Master_key.t -> aad:string -> string -> string

(** Fails on a wrong key, a wrong [aad], a truncated or modified box, or an unknown
    version, without saying which. *)
val open_ : Master_key.t -> aad:string -> string -> string Or_error.t

(** Lowercase hex, for storing boxes in text files. *)
val to_hex : string -> string

val of_hex : string -> string Or_error.t
