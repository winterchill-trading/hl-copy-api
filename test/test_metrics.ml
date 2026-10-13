open! Core
open Hl_copy_api

let%expect_test "render" =
  let t = Metrics.create () in
  let ms = Time_ns.Span.of_int_ms in
  Metrics.request t ~route:"/follows/:id" ~meth:"GET" ~status:200 ~duration:(ms 3);
  Metrics.request t ~route:"/follows/:id" ~meth:"GET" ~status:200 ~duration:(ms 5);
  Metrics.request t ~route:"/auth/verify" ~meth:"POST" ~status:401 ~duration:(ms 1);
  Metrics.incr t "logins";
  Metrics.gauge t "challenges_outstanding" (fun () -> 2.);
  print_string (Metrics.render t);
  [%expect
    {|
    # TYPE hl_copy_api_requests_total counter
    hl_copy_api_requests_total{route="/auth/verify",method="POST",status="401"} 1
    hl_copy_api_requests_total{route="/follows/:id",method="GET",status="200"} 2
    # TYPE hl_copy_api_request_seconds_sum counter
    hl_copy_api_request_seconds_sum{route="/auth/verify",method="POST",status="401"} 0.001000
    hl_copy_api_request_seconds_sum{route="/follows/:id",method="GET",status="200"} 0.008000
    # TYPE hl_copy_api_logins_total counter
    hl_copy_api_logins_total 1
    # TYPE hl_copy_api_challenges_outstanding gauge
    hl_copy_api_challenges_outstanding 2
    |}]
;;
