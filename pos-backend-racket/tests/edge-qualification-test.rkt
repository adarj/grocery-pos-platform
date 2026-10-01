#lang racket
(require rackunit json racket/unix-socket
         "edge-client-framing-test.rkt"
         "../pos/edge/client.rkt" "../pos/edge/protocol.rkt" "../pos/edge/session.rkt")
(define health (jsexpr->bytes (hasheq 'agent_instance_id "a" 'protocol_version (hasheq 'major 1 'minor 0))))
(define (snapshot [agent "a"] [cursor 0] [uptime 0] [devices null]) (edge-snapshot-event agent cursor uptime devices))
(module+ test
  (test-case "qualification default NDJSON byte boundary, whitespace, CRLF and partial EOF"
    (check-equal? event-record-max-bytes 65536)
    (define exact (bytes-append #"{}" (make-bytes (- event-record-max-bytes 2) 32)))
    (check-equal? (decode-edge-json (read-edge-record (open-input-bytes (bytes-append exact #"\n")))) (hasheq))
    (for ([bad (in-list (list (bytes-append exact #" \n") (bytes-append exact #" ") exact))])
      (check-exn exn:fail:edge-protocol? (lambda () (read-edge-record (open-input-bytes bad)))))
    (check-equal? (decode-edge-json (read-edge-record (open-input-bytes #"{}\r\n"))) (hasheq))
    (for ([bad '(#"{}{}\n" #"{\"x\":\"\377\"}\n")])
      (check-exn exn:fail:edge-protocol? (lambda () (decode-edge-json (read-edge-record (open-input-bytes bad)))))))
  (test-case "qualification fragmented UTF-8 and newlines across HTTP chunks"
    (define record (bytes-append (jsexpr->bytes (hasheq 'type "snapshot" 'agent_instance_id "aé" 'event_cursor 0 'agent_uptime_ms 1 'devices null)) #"\n"))
    ;; Each byte is a distinct HTTP chunk, including both UTF-8 bytes and LF.
    (define chunks (apply bytes-append (for/list ([byte (in-bytes record)]) (bytes-append #"1\r\n" (bytes byte) #"\r\n"))))
    (with-peer (bytes-append #"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" chunks #"0\r\n\r\n")
      (lambda (client _listener _served)
        (define stream (edge-open-events client))
        (dynamic-wind void
          (lambda () (check-equal? (edge-snapshot-event-agent-id (parse-edge-event (decode-edge-json (read-edge-record (edge-stream-input stream))))) "aé"))
          (lambda () (close-edge-stream! stream))))))
  (test-case "qualification redirects 301/302/307/308 never transmit a POST twice"
    (for* ([code '(301 302 307 308)] [location '("/v1/commands" "http://127.0.0.1:9/v1/commands" "http+unix://%2Ftmp%2Fother.sock/v1/commands")])
      (with-peer (fixed (string->bytes/utf-8 (format "HTTP/1.1 ~a Redirect" code)) #"{}"
                        (string->bytes/utf-8 (format "Location: ~a\r\n" location)))
        (lambda (client listener served)
          (define a (make-edge-command-attempt #:agent-id "a" #:device-id "d" #:binding-id "b" #:not-after 100 #:timeout 10 #:payload (make-edge-payload "synthetic.signal" (hasheq 'token 1))))
          (check-true (edge-malformed-response? (edge-submit-command client a)))
          (check-not-false (sync/timeout 1 served))
          (check-false (sync/timeout .02 (unix-socket-accept-evt listener)))))))
  (test-case "qualification response bounds apply to CL and chunked error bodies without retries"
    (define oversized (make-bytes (add1 non-stream-max-bytes) 32))
    (for ([response (in-list (list (fixed #"HTTP/1.1 503 Unavailable" oversized)
                                   (bytes-append #"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                                                 (string->bytes/utf-8 (number->string (bytes-length oversized) 16)) #"\r\n" oversized #"\r\n0\r\n\r\n")))])
      (with-peer response (lambda (client listener served)
        (check-equal? (edge-malformed-response-code (edge-health client)) 'response-too-large)
        (check-not-false (sync/timeout 1 served))
        (check-false (sync/timeout .02 (unix-socket-accept-evt listener)))))))
  (test-case "qualification malformed chunks and oversized trailers never become valid responses"
    (define prefix #"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    (define chunk (bytes-append (string->bytes/utf-8 (number->string (bytes-length health) 16)) #"\r\n" health #"\r\n"))
    (for ([suffix (in-list (list #"0\r\n" #"0\r\nX: incomplete" #"-1\r\n" #"xyz\r\n"
                                 (bytes-append #"0\r\nX: " (make-bytes 16385 120) #"\r\n\r\n")
                                 #"0\r\nContent-Length: 0\r\n\r\n"))] [index (in-naturals)])
      (with-peer (bytes-append prefix chunk suffix)
        (lambda (client listener served)
          (check-false (edge-response? (edge-health client)) (format "framing case ~a" index))
          (check-not-false (sync/timeout 1 served))
          (check-false (sync/timeout .02 (unix-socket-accept-evt listener)))))))
  (test-case "qualification partial snapshot validation cannot install a partial device cache"
    (define valid (hasheq 'agent_instance_id "a" 'device_id "d" 'binding_instance_id "b" 'state_revision 5 'adapter_kind "synthetic" 'availability "ready" 'conditions null 'capabilities '("synthetic.signal")))
    (check-exn exn:fail:edge-protocol?
      (lambda () (parse-edge-event (hasheq 'type "snapshot" 'agent_instance_id "a" 'event_cursor 0 'agent_uptime_ms 1
                                          'devices (list valid (hash-set valid 'availability "unsafe-new-meaning")))))))
  (test-case "qualification session first record, uptime regression, unknown device and epoch reset"
    (define empty (empty-edge-session-state))
    (check-equal? (edge-session-state-health (edge-session-apply empty (edge-heartbeat "a" 10))) 'stale)
    (define state (edge-session-apply empty (snapshot "a" 27 100)))
    (check-equal? (edge-session-state-health (edge-session-apply state (edge-heartbeat "a" 99))) 'stale)
    (define unknown (edge-device-snapshot "a" "unknown" "b" 1 "synthetic" 'ready null '("synthetic.signal")))
    (check-equal? (edge-session-state-health (edge-session-apply state (edge-device-event "a" 28 unknown))) 'stale)
    (define new (edge-session-apply (edge-session-reconnecting state) (snapshot "b" 0 0)))
    (check-equal? (edge-session-state-health new) 'healthy)
    (check-equal? (edge-session-state-cursor new) 0)
    (check-equal? (edge-session-state-uptime new) 0)))
