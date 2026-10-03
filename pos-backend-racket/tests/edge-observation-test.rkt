#lang racket/base

(require rackunit json racket/file racket/list racket/string
         "../pos/edge/protocol.rkt"
         "../pos/edge/session.rkt"
         "../pos/edge/client.rkt"
         "edge-process-test.rkt")

(define device
  (edge-device-snapshot "agent" "scanner" "binding" 3 "synthetic" 'ready null '("scanner.barcode")))

(define (event [sequence 11] [barcode "049000001234"])
  (hasheq 'type "device.observation" 'agent_instance_id "agent" 'sequence sequence
          'device_id "scanner" 'binding_instance_id "binding" 'state_revision 3
          'observation (hasheq 'kind "scanner.barcode" 'barcode barcode)))

(define (initial)
  (edge-session-apply (empty-edge-session-state) (edge-snapshot-event "agent" 10 100 (list device)) 1000))

(define (release f)
  (call-with-output-file (path-replace-extension (fixture-metrics f) #".observations") void))

(module+ test
  (test-case "barcode is immutable opaque UTF-8 with a byte ceiling and redacted diagnostics"
    (for ([v (in-list (list "0" " 049000001234 " "\u0000\n\t" (make-string 4096 #\a) (make-string 1024 #\🦀)))])
      (define parsed
        (parse-edge-event (decode-edge-json (string->bytes/utf-8 (jsexpr->string (event 11 v))))))
      (define value (edge-scanner-barcode-barcode (edge-observation-event-observation parsed)))
      (check-equal? value v)
      (check-true (immutable? value))
      (check-false (string-contains? (format "~s" parsed) v)))
    (define private (parse-edge-event (event 11 "PRIVATE_PRINT_BARCODE")))
    (define printed (open-output-string))
    (write private printed)
    (display private printed)
    (check-false (string-contains? (format "~a ~s ~a" private private (get-output-string printed))
                                   "PRIVATE_PRINT_BARCODE"))
    (for ([v (in-list (list "" 1 'null (make-string 4097 #\a) (make-string 1025 #\🦀)))])
      (check-exn exn:fail:edge-protocol? (lambda () (parse-edge-event (event 11 v)))))
    (define bad (event 11 "PRIVATE_BARCODE_SENTINEL"))
    (for ([obj (in-list (list
                          (hash-set bad 'binding_instance_id 'null)
                          (hash-set bad 'sequence -1)
                          (hash-set bad 'state_revision "3")
                          (hash-set bad 'device_id "")
                          (hash-set bad 'observation (hasheq 'kind "scanner.bytes" 'barcode "PRIVATE_BARCODE_SENTINEL"))
                          (hash-set bad 'observation (hasheq 'kind "scanner.barcode"))
                          (hash-set bad 'observation (hasheq 'kind "scanner.barcode" 'barcode "PRIVATE_BARCODE_SENTINEL" 'raw "PRIVATE_BARCODE_SENTINEL"))))])
      (with-handlers ([exn:fail:edge-protocol?
                       (lambda (e) (check-false (string-contains? (format "~s ~a" e (exn-message e)) "PRIVATE_BARCODE_SENTINEL")))])
        (parse-edge-event obj)
        (fail "invalid observation accepted"))))

  (test-case "observations share sequence and preserve snapshot without history or value dedupe"
    (define first (edge-session-apply (initial) (parse-edge-event (event)) 1010))
    (define second (edge-session-apply first (parse-edge-event (event 12)) 1020))
    (check-equal? (edge-session-state-health second) 'healthy)
    (check-equal? (edge-session-state-cursor second) 12)
    (check-eq? (edge-session-state-devices second) (edge-session-state-devices first))
    (check-false (string-contains? (format "~s" second) "049000001234"))
    (define next-device (struct-copy edge-device-snapshot device [revision 4]))
    (define changed (edge-session-apply (initial) (edge-device-event "agent" 11 next-device) 1010))
    (define observed (edge-session-apply changed (parse-edge-event (hash-set (event 12) 'state_revision 4)) 1020))
    (check-equal? (edge-session-state-health observed) 'healthy)
    (check-equal? (edge-session-state-cursor observed) 12)
    (define duplicate (edge-session-apply first (parse-edge-event (event)) 1020))
    (check-equal? (edge-session-state-failure duplicate) 'sequence-gap)
    (check-equal? (edge-session-state-cursor duplicate) 11))

  (test-case "gaps wrong agent device binding revision and unavailable capability fail closed"
    (for ([obj (in-list (list (event 12) (event 10) (event 9)
                              (hash-set (event) 'agent_instance_id "other")
                              (hash-set (event) 'device_id "unknown")
                              (hash-set (event) 'binding_instance_id "old")
                              (hash-set (event) 'state_revision 2)))])
      (define next (edge-session-apply (initial) (parse-edge-event obj) 1010))
      (check-equal? (edge-session-state-health next) 'stale)
      (check-equal? (edge-session-state-cursor next) 10)
      (check-equal? (edge-session-state-devices next) (edge-session-state-devices (initial))))
    (define no-cap (struct-copy edge-device-snapshot device [capabilities null]))
    (define state (edge-session-apply (empty-edge-session-state) (edge-snapshot-event "agent" 10 100 (list no-cap)) 1000))
    (check-equal? (edge-session-state-failure (edge-session-apply state (parse-edge-event (event)) 1010)) 'observation-state))

  (test-case "real UDS source supervisor Core NDJSON parser session delivers identical scans twice"
    (with-fixture "observations"
                  (lambda (f)
                    (define received (box null))
                    (define session (start-edge-session (fixture-client f)
                                                        #:on-observation (lambda (e) (set-box! received (append (unbox received) (list e))))))
                    (dynamic-wind
                      void
                      (lambda ()
                        (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current session)))))
                        (define cursor (edge-session-state-cursor (edge-session-current session)))
                        (release f)
                        (check-true (wait-until (lambda () (= (length (unbox received)) 3))))
                        (check-equal? (map edge-observation-event-sequence (unbox received)) (list (+ cursor 1) (+ cursor 2) (+ cursor 3)))
                        (check-equal? (map (lambda (e) (edge-scanner-barcode-barcode (edge-observation-event-observation e))) (unbox received)) '("049000001234" "049000001234" "other"))
                        (check-equal? (string->number (first (metrics f))) 0)
                        (check-equal? (string->number (third (metrics f))) 0)
                        (check-equal? (metric-value f "retained") 0))
                      (lambda () (stop-edge-session! session))))))

  (test-case "callback failure closes the stream with a safe authored failure"
    (with-fixture "observations"
      (lambda (f)
        (define session
          (start-edge-session (fixture-client f)
                              #:on-observation (lambda (_) (error 'callback "PRIVATE_BARCODE_CALLBACK"))))
        (dynamic-wind void
          (lambda ()
            (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current session)))))
            (release f)
            (check-true (wait-until (lambda () (eq? (edge-session-state-health (edge-session-current session)) 'stale))))
            (check-equal? (edge-session-state-failure (edge-session-current session)) 'observation-callback)
            (check-false (string-contains? (format "~s" (edge-session-current session)) "PRIVATE_BARCODE_CALLBACK")))
          (lambda () (stop-edge-session! session))))))

  (test-case "raised callback values fail closed without diagnostic payloads"
    (with-fixture "observations"
      (lambda (f)
        (define errors (open-output-string))
        (define calls 0)
        (define session
          (parameterize ([current-error-port errors])
            (start-edge-session (fixture-client f)
              #:on-observation
              (lambda (_)
                (set! calls (add1 calls))
                (raise "PRIVATE_CALLBACK_RAISED_VALUE")))))
        (dynamic-wind void
          (lambda ()
            (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current session)))))
            (define cursor (edge-session-state-cursor (edge-session-current session)))
            (release f)
            (check-true (wait-until (lambda () (eq? (edge-session-state-health (edge-session-current session)) 'stale))))
            (check-equal? (edge-session-state-failure (edge-session-current session)) 'observation-callback)
            (check-equal? (edge-session-state-cursor (edge-session-current session)) (add1 cursor))
            (check-equal? calls 1)
            (check-false (string-contains? (get-output-string errors) "PRIVATE_CALLBACK_RAISED_VALUE")))
          (lambda () (stop-edge-session! session))))))

  (test-case "escaping callback cannot leave a closed session healthy"
    (with-fixture "observations"
      (lambda (f)
        (define calls 0)
        (define session
          (start-edge-session (fixture-client f)
            #:on-observation
            (lambda (_)
              (set! calls (add1 calls))
              (abort-current-continuation (default-continuation-prompt-tag) void))))
        (dynamic-wind void
          (lambda ()
            (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current session)))))
            (release f)
            (check-true (wait-until (lambda () (eq? (edge-session-state-health (edge-session-current session)) 'stale))))
            (check-equal? (edge-session-state-failure (edge-session-current session)) 'observation-callback)
            (check-equal? calls 1))
          (lambda () (stop-edge-session! session))))))


  (test-case "callback abort payload is never executed outside the privacy boundary"
    (with-fixture "observations"
      (lambda (f)
        (define errors (open-output-string))
        (define ran-payload (box #f))
        (define session
          (parameterize ([current-error-port errors])
            (start-edge-session (fixture-client f)
              #:on-observation
              (lambda (_)
                (abort-current-continuation (default-continuation-prompt-tag)
                  (lambda ()
                    (set-box! ran-payload #t)
                    (error 'callback "PRIVATE_ABORT_BARCODE")))))))
        (dynamic-wind void
          (lambda ()
            (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current session)))))
            (release f)
            (check-true (wait-until (lambda () (eq? (edge-session-state-failure (edge-session-current session)) 'observation-callback))))
            (check-false (unbox ran-payload))
            (check-false (string-contains? (get-output-string errors) "PRIVATE_ABORT_BARCODE")))
          (lambda () (stop-edge-session! session))))))

  (test-case "callback sees committed cursor and can stop without resurrecting health"
    (with-fixture "observations"
      (lambda (f)
        (define entered (make-semaphore 0))
        (define observed (box #f))
        (define session #f)
        (set! session
          (start-edge-session (fixture-client f)
            #:on-observation
            (lambda (e)
              (set-box! observed (list (edge-session-state-cursor (edge-session-current session))
                                      (edge-observation-event-sequence e)))
              (semaphore-post entered)
              (stop-edge-session! session))))
        (dynamic-wind void
          (lambda ()
            (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current session)))))
            (release f)
            (check-not-false (sync/timeout 4 entered))
            (check-equal? (first (unbox observed)) (second (unbox observed)))
            (check-true (wait-until (lambda () (eq? (edge-session-state-failure (edge-session-current session)) 'stopped))))
            (check-equal? (edge-session-state-health (edge-session-current session)) 'stale))
          (lambda () (stop-edge-session! session))))))

  (test-case "external stop while callback waits cannot be undone by callback completion"
    (with-fixture "observations"
      (lambda (f)
        (define entered (make-semaphore 0))
        (define resume (make-semaphore 0))
        (define returned (box #f))
        (define session
          (start-edge-session (fixture-client f)
            #:on-observation (lambda (_)
                               (semaphore-post entered)
                               (sync resume)
                               (set-box! returned #t))))
        (dynamic-wind void
          (lambda ()
            (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current session)))))
            (release f)
            (check-not-false (sync/timeout 4 entered))
            (stop-edge-session! session)
            (semaphore-post resume)
            (check-false (unbox returned))
            (check-equal? (edge-session-state-health (edge-session-current session)) 'stale)
            (check-equal? (edge-session-state-failure (edge-session-current session)) 'stopped))
          (lambda () (stop-edge-session! session))))))

  (test-case "failed callback consumes one ephemeral scan without retry or reconnect replay"
    (with-fixture "observations"
      (lambda (f)
        (define calls 0)
        (define failed
          (start-edge-session (fixture-client f)
            #:on-observation (lambda (_) (set! calls (add1 calls)) (error 'callback "PRIVATE_RECONNECT_BARCODE"))))
        (dynamic-wind void
          (lambda ()
            (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current failed)))))
            (define before (edge-session-state-cursor (edge-session-current failed)))
            (release f)
            (check-true (wait-until (lambda () (eq? (edge-session-state-failure (edge-session-current failed)) 'observation-callback))))
            (check-equal? calls 1)
            (check-equal? (edge-session-state-cursor (edge-session-current failed)) (add1 before))
            (check-true (wait-until (lambda () (= (metric-value f "observations") 3))))
            (define previous (edge-session-current failed))
            (stop-edge-session! failed)
            (define next
              (start-edge-session (fixture-client f) #:previous previous
                #:on-observation (lambda (_) (set! calls (add1 calls)))))
            (dynamic-wind void
              (lambda ()
                (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current next)))))
                (check-equal? calls 1)
                (check-equal? (edge-session-state-cursor (edge-session-current next)) (+ before 3)))
              (lambda () (stop-edge-session! next))))
          (lambda () (stop-edge-session! failed))))))

  (test-case "major one metadata accepts legacy and future minors without authorizing unknown events"
    (for ([minor '(0 1 2 65535)])
      (define obj (hasheq 'agent_instance_id "agent" 'protocol_version (hasheq 'major 1 'minor minor)
                          'agent_uptime_ms 100))
      (check-equal? (edge-health-state-minor (parse-edge-health obj)) minor)
      (check-equal? (edge-agent-status-minor (parse-edge-status obj)) minor))
    (check-exn exn:fail:edge-protocol?
      (lambda () (parse-edge-event (hash-set (event) 'type "device.future_observation")))))

  (test-case "current client consumes legacy 1.0 and current 1.1 real event streams"
    (for ([mode '("version-1-0" "")] [minor '(0 1)])
      (with-fixture mode
        (lambda (f)
          (check-equal? (edge-health-state-minor (edge-response-value (edge-health (fixture-client f)))) minor)
          (check-equal? (edge-agent-status-minor (edge-response-value (edge-status (fixture-client f)))) minor)
          (define commands (box null))
          (define session (start-edge-session (fixture-client f)
                             #:on-command (lambda (c) (set-box! commands (cons c (unbox commands))))))
          (dynamic-wind void
            (lambda ()
              (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current session)))))
              (define command (attempt f))
              (check-equal? (edge-response-status (edge-submit-command (fixture-client f) command)) 202)
              (check-true (wait-until (lambda () (for/or ([c (in-list (unbox commands))])
                                                   (eq? (edge-command-state-outcome c) 'succeeded)))))
              (check-equal? (edge-session-state-health (edge-session-current session)) 'healthy))
            (lambda () (stop-edge-session! session)))))))

  (test-case "missed real observations are not replayed on session reconnect"
    (with-fixture "observations"
                  (lambda (f)
                    (define old (start-edge-session (fixture-client f)))
                    (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current old)))))
                    (stop-edge-session! old)
                    (release f)
                    (check-true (wait-until (lambda () (= (metric-value f "observations") 3))))
                    (define received (box null))
                    (define next (start-edge-session (fixture-client f) #:previous (edge-session-current old)
                                                     #:on-observation (lambda (e) (set-box! received (cons e (unbox received))))))
                    (dynamic-wind void
                                  (lambda ()
                                    (check-true (wait-until (lambda () (edge-session-healthy? (edge-session-current next)))))
                                    (check-equal? (unbox received) null)
                                    (check-equal? (edge-session-state-cursor (edge-session-current next)) 5))
                                  (lambda () (stop-edge-session! next)))))))
