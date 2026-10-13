open! Core

let of_bytes s = String.concat_map s ~f:(fun c -> sprintf "%02x" (Char.to_int c))

let to_bytes hex =
  let n = String.length hex in
  if n % 2 <> 0 || not (String.for_all hex ~f:Char.is_hex_digit)
  then Or_error.error_s [%message "not an even number of hex digits" (n : int)]
  else
    Ok
      (String.init (n / 2) ~f:(fun i ->
         Char.of_int_exn (Int.of_string ("0x" ^ String.sub hex ~pos:(2 * i) ~len:2))))
;;

let random n = of_bytes (Cryptokit.Random.string Cryptokit.Random.secure_rng n)
