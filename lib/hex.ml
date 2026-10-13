open! Core

let of_bytes s = String.concat_map s ~f:(fun c -> sprintf "%02x" (Char.to_int c))
let random n = of_bytes (Cryptokit.Random.string Cryptokit.Random.secure_rng n)
