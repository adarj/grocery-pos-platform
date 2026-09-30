#lang racket/base
(require rackunit json racket/port racket/string
         "../pos/edge/protocol.rkt" "../pos/edge/client.rkt" "../pos/edge/session.rkt")
(define device
  (hasheq 'agent_instance_id "a" 'device_id "d" 'binding_instance_id "b"
          'state_revision 5 'adapter_kind "synthetic.scripted" 'availability "ready"
          'conditions null 'capabilities '("synthetic.signal")))
(module+ test
  (test-case "typed response parsing tolerates additions but rejects unknown safety meanings"
    (define parsed (parse-edge-device (hash-set device 'additive "ignored")))
    (check-true (edge-device-snapshot? parsed))
    (check-exn exn:fail:edge-protocol? (lambda () (parse-edge-device (hash-set device 'availability "optimistically_ready"))))
    (for ([bad (list -1 1.5 (expt 2 64) "5")])
      (check-exn exn:fail:edge-protocol? (lambda () (parse-edge-device (hash-set device 'state_revision bad)))))
    (check-exn exn:fail:edge-protocol? (lambda () (parse-edge-device (hash-set device 'device_id (make-string 257 #\a)))))
    (check-exn exn:fail:edge-protocol? (lambda () (parse-edge-device (hash-set device 'binding_instance_id 'null)))))
  (test-case "bounded framing stops before unbounded allocation and validates exact UTF-8 document"
    (check-equal? (read-edge-record (open-input-bytes #"{}\n{}\n") 2) #"{}")
    (check-exn exn:fail:edge-protocol? (lambda () (read-edge-record (open-input-bytes #"1234\n") 3)))
    (check-exn exn:fail:edge-protocol? (lambda () (read-edge-record (open-input-bytes #"{}") 4)))
    (check-exn exn:fail:edge-protocol? (lambda () (read-edge-body (open-input-bytes #"1234") 3)))
    (check-equal? (read-edge-body (open-input-bytes #"123") 3) #"123")
    (for ([bad (list #"{} {}" (bytes 255) #"{\"x\":\"\\uD800\"}" #"{}garbage")])
      (check-exn exn:fail:edge-protocol? (lambda () (decode-edge-json bad)))))
  (test-case "semantic attempt captures immutable fields and stays redacted"
    (define kind (string-copy "synthetic.signal"))
    (define payload (make-edge-payload kind (hasheq 'secret "synthetic-private-marker")))
    (define attempt (make-edge-command-attempt #:agent-id "a" #:device-id "d" #:binding-id "b" #:not-after 100 #:timeout 10 #:payload payload))
    (string-set! kind 0 #\X)
    (check-equal? (edge-command-attempt-kind attempt) "synthetic.signal")
    (check-equal? (edge-command-attempt-command-id attempt) (edge-command-attempt-command-id attempt))
    (check-false (string-contains? (format "~s ~s" payload attempt) "synthetic-private-marker"))
    (define other (make-edge-command-attempt #:agent-id "a" #:device-id "d" #:binding-id "b" #:not-after 100 #:timeout 10 #:payload payload))
    (check-not-equal? (edge-command-attempt-command-id other) (edge-command-attempt-command-id attempt)))
  (test-case "attempt command identity cannot be mutated through its public accessor"
    (define attempt (make-edge-command-attempt #:agent-id "a" #:device-id "d" #:binding-id "b" #:not-after 100 #:timeout 10
                                              #:payload (make-edge-payload "synthetic.signal" (hasheq 'token 1))))
    (define command-id (edge-command-attempt-command-id attempt))
    (check-true (immutable? command-id))
    (check-exn exn:fail:contract? (lambda () (string-set! command-id 0 #\X)))
    (check-equal? (edge-command-attempt-command-id attempt) command-id))
  (test-case "client configuration cannot disable time bounds with infinity"
    (check-exn exn:fail:contract? (lambda () (make-edge-client "/tmp/edge.sock" #:timeout +inf.0))))
  (test-case "snapshot establishes cursor and heartbeat never advances it"
    (define d (parse-edge-device device))
    (define state (edge-session-apply (empty-edge-session-state) (edge-snapshot-event "a" 27 100 (list d)) 1000))
    (check-equal? (edge-session-state-health state) 'healthy)
    (define heart (edge-session-apply state (edge-heartbeat "a" 110) 1010))
    (check-equal? (edge-session-state-cursor heart) 27)
    (check-equal? (edge-session-estimated-uptime heart 1020) 120)
    (define updated (struct-copy edge-device-snapshot d [revision 6] [availability 'degraded]))
    (define next (edge-session-apply heart (edge-device-event "a" 28 updated) 1020))
    (check-equal? (edge-session-state-cursor next) 28)
    (check-equal? (hash-ref (edge-session-state-devices next) "d") updated)
    (check-false (edge-session-healthy? next #:stale-ms 10 #:now 1031)))
  (test-case "sequence/revision/epoch violations mark stale without moving cache"
    (define d (parse-edge-device device))
    (define state (edge-session-apply (empty-edge-session-state) (edge-snapshot-event "a" 27 100 (list d)) 1000))
    (for ([seq '(27 26 29)])
      (check-equal? (edge-session-state-failure (edge-session-apply state (edge-device-event "a" seq (struct-copy edge-device-snapshot d [revision 6])) 1010)) 'sequence-gap))
    (check-equal? (edge-session-state-failure (edge-session-apply state (edge-device-event "a" 28 (struct-copy edge-device-snapshot d [revision 7])) 1010)) 'revision-gap)
    (check-equal? (edge-session-state-failure (edge-session-apply state (edge-heartbeat "b" 110) 1010)) 'agent-mismatch)
    (check-equal? (edge-session-state-failure (edge-session-apply state (edge-snapshot-event "a" 27 100 (list d)) 1010)) 'unexpected-snapshot)
    (define replaced (edge-session-apply (edge-session-reconnecting state) (edge-snapshot-event "b" 0 1 null) 1010))
    (check-equal? (edge-session-state-agent-id replaced) "b")
    (check-equal? (hash-count (edge-session-state-devices replaced)) 0))
  (test-case "reconnection in the same epoch cannot roll cursor or device revision backward"
    (define d (parse-edge-device device))
    (define state (edge-session-apply (empty-edge-session-state) (edge-snapshot-event "a" 27 100 (list d)) 1000))
    (for ([snapshot (in-list (list (edge-snapshot-event "a" 26 110 (list d))
                                  (edge-snapshot-event "a" 28 110 (list (struct-copy edge-device-snapshot d [revision 4])))))])
      (define next (edge-session-apply (edge-session-reconnecting state) snapshot 1010))
      (check-equal? (edge-session-state-health next) 'stale)
      (check-equal? (edge-session-state-cursor next) 27)
      (check-equal? (edge-session-state-devices next) (edge-session-state-devices state)))))
