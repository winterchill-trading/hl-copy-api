open! Core
open Hl_protocol

module Entry = struct
  type t =
    { address : Address.t
    ; message : string
    ; expires : Time_ns.t
    ; seq : int
    }
end

type t =
  { ttl : Time_ns.Span.t
  ; max_outstanding : int
  ; domain : string
  ; uri : string
  ; chain_id : int
  ; by_nonce : Entry.t String.Table.t
  ; mutable seq : int
  }

let create
  ?(ttl = Time_ns.Span.of_min 5.)
  ?(max_outstanding = 100_000)
  ~domain
  ~uri
  ~chain_id
  ()
  =
  { ttl
  ; max_outstanding
  ; domain
  ; uri
  ; chain_id
  ; by_nonce = String.Table.create ()
  ; seq = 0
  }
;;

let outstanding t = Hashtbl.length t.by_nonce

let checksum_address address =
  let hex = String.drop_prefix (Address.to_string address) 2 |> String.lowercase in
  let hash = Hl_client.Keccak.digest_hex hex in
  "0x"
  ^ String.mapi hex ~f:(fun i c ->
    let nibble = Int.of_string ("0x" ^ String.of_char hash.[i]) in
    if Char.is_alpha c && nibble >= 8 then Char.uppercase c else c)
;;

let iso time = Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc

let message t ~address ~nonce ~issued ~expires =
  String.concat
    ~sep:"\n"
    [ sprintf "%s wants you to sign in with your Ethereum account:" t.domain
    ; checksum_address address
    ; ""
    ; "Sign in to hl-copy. This request does not trigger a transaction or cost any fee."
    ; ""
    ; sprintf "URI: %s" t.uri
    ; "Version: 1"
    ; sprintf "Chain ID: %d" t.chain_id
    ; sprintf "Nonce: %s" nonce
    ; sprintf "Issued At: %s" (iso issued)
    ; sprintf "Expiration Time: %s" (iso expires)
    ]
;;

let prune t ~now =
  Hashtbl.filter_inplace t.by_nonce ~f:(fun e -> Time_ns.( > ) e.expires now);
  let excess = Hashtbl.length t.by_nonce - t.max_outstanding + 1 in
  if excess > 0
  then
    Hashtbl.to_alist t.by_nonce
    |> List.sort ~compare:(fun (_, (a : Entry.t)) (_, b) -> Int.compare a.seq b.seq)
    |> Fn.flip List.take excess
    |> List.iter ~f:(fun (nonce, _) -> Hashtbl.remove t.by_nonce nonce)
;;

let ms time = Float.of_int (Time_ns.to_int_ns_since_epoch time / 1_000_000)

let issue ?nonce t address ~now =
  prune t ~now;
  let nonce =
    match nonce with
    | Some nonce -> nonce
    | None -> Hl_copy_keystore.Sealed.(to_hex (random_bytes 8))
  in
  let expires = Time_ns.add now t.ttl in
  let message = message t ~address ~nonce ~issued:now ~expires in
  t.seq <- t.seq + 1;
  Hashtbl.set t.by_nonce ~key:nonce ~data:{ address; message; expires; seq = t.seq };
  { Api_types.Auth.Challenge.message; nonce; expires_at = ms expires }
;;

let consume t address ~nonce ~now =
  let found =
    match nonce with
    | Some nonce -> Option.map (Hashtbl.find t.by_nonce nonce) ~f:(fun e -> nonce, e)
    | None ->
      Hashtbl.fold t.by_nonce ~init:None ~f:(fun ~key ~data best ->
        if not (Address.equal data.address address)
        then best
        else (
          match best with
          | Some (_, (b : Entry.t)) when b.seq > data.seq -> best
          | _ -> Some (key, data)))
  in
  match found with
  | None -> Or_error.error_string "no outstanding challenge"
  | Some (nonce, entry) ->
    if not (Address.equal entry.address address)
    then Or_error.error_string "no outstanding challenge"
    else (
      Hashtbl.remove t.by_nonce nonce;
      if Time_ns.( <= ) entry.expires now
      then Or_error.error_string "challenge expired"
      else Ok entry.message)
;;
