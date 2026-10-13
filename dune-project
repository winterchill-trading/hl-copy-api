(lang dune 3.17)

(name hl-copy-api)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/hl-copy-api))

(package
 (name hl-copy-keystore)
 (synopsis "Encrypted agent key files shared by the copy-trading API and engine")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  cryptokit
  ppx_jane))

(package
 (name hl-copy-api)
 (synopsis
  "HTTP API of the Hyperliquid copy-trading platform: wallet login, agent keys, follows")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  cohttp
  cohttp-async
  http
  async_websocket
  cryptokit
  uri
  yojson
  ppx_jane
  ppx_yojson_conv
  (hl-copy-keystore
   (= :version))
  hl-protocol
  hl-client
  hl-copy-core
  hl-copy-api-types
  market-data
  venue-net
  (hl-sim :with-test)
  (hl-leaderboard :with-test)))
