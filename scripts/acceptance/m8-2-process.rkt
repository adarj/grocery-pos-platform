#lang racket

(require json
         racket/file
         racket/match
         "../../pos-backend-racket/tests/edge-process-test.rkt"
         "../../pos-backend-racket/pos/edge/client.rkt"
         "../../pos-backend-racket/pos/edge/protocol.rkt"
         "../../pos-backend-racket/pos/edge/session.rkt")

;; Finite qualification workloads, never normal runtime or automatic recovery.
(define (ensure ok code)
  (unless ok
    (raise-user-error 'm8-2-process code)))

(define (current-command client a)
  (define result (edge-command-status client (edge-command-attempt-command-id a)))
  (ensure (edge-response? result) "command lookup unavailable")
  (edge-response-value result))

(define (healthy session)
  (eq? (edge-session-state-health (edge-session-current session)) 'healthy))

(define campaign-directory (make-parameter #f))

(define (new-directory)
  (make-temporary-file "edge-cycle-~a" 'directory (campaign-directory)))

(define (with-campaign-fixture mode work)
  (define f (start-fixture mode "fixture-agent" (new-directory)))
  (dynamic-wind void (lambda () (work f)) (lambda () (stop-fixture f))))

(define (resident-memory f)
  ;; Allowlisted numeric Linux observations only; no process identity/status dump.
  (with-handlers ([exn:fail? (lambda (_) (hash))])
    (call-with-input-file
     (format "/proc/~a/status" (subprocess-pid (fixture-process f)))
     (lambda (in)
       (for/fold ([values (hash)]) ([line (in-lines in)])
         (define match (regexp-match #px"^Vm(RSS|HWM):\\s+([0-9]+)\\s+kB$" line))
         (if match (hash-set values (second match) (string->number (third match))) values))))))

(define (load-campaign count)
  (with-campaign-fixture
   ""
   (lambda (f)
     (define observed (make-hash))
     (define event-count 0)
     (define session
       (start-edge-session
        (fixture-client f)
        #:stale-ms 3000
        #:on-command (lambda (c)
                       (set! event-count (add1 event-count))
                       (hash-update!
                        observed
                        (edge-command-state-command-id c)
                        (lambda (phases) (append phases (list (edge-command-state-phase c))))
                        null))))
     (define start (current-inexact-monotonic-milliseconds))
     (dynamic-wind
      void
      (lambda ()
        (ensure (wait-until (lambda () (healthy session))) "initial snapshot missing")
        (define initial (edge-session-current session))
        (for ([n (in-range count)])
          (define a (attempt f))
          (define new (edge-submit-command (fixture-client f) a))
          (ensure
           (and (edge-response? new) (= (edge-response-status new) 202))
           "new attempt refused")
          ;; Explicit caller replay; no library/session retry. Same identity.
          (define duplicate (edge-submit-command (fixture-client f) a))
          (ensure
           (and (edge-response? duplicate) (= (edge-response-status duplicate) 200))
           "dedupe missing")
          (ensure
           (wait-until
            (lambda ()
              (equal?
               (hash-ref observed (edge-command-attempt-command-id a) #f)
               '(accepted executing terminal))))
           "command event ordering")
          (define terminal (current-command (fixture-client f) a))
          (ensure
           (and
            (eq? (edge-command-state-outcome terminal) 'succeeded)
            (eq? (edge-command-state-evidence terminal) 'confirmed))
           "terminal uncertainty corruption")
          (ensure (healthy session) "stream lost continuity")
          ;; Bound harness memory too: only one command's phases at a time.
          (hash-remove! observed (edge-command-attempt-command-id a)))
        (define final (edge-session-current session))
        (ensure
         (= (- (edge-session-state-cursor final) (edge-session-state-cursor initial)) (* 3 count))
         "global sequence mismatch")
        (ensure
         (equal? (edge-session-state-devices final) (edge-session-state-devices initial))
         "device revisions changed unexpectedly")
        (define counts (map string->number (take (metrics f) 3)))
        (ensure (equal? counts (list (* 2 count) count count)) "request/physical-start cardinality")
        (define high-water (metric-value f "command_high_water"))
        (ensure (and high-water (<= high-water 4096)) "command cache exceeded default bound")
        (define memory (resident-memory f))
        (define elapsed (/ (- (current-inexact-monotonic-milliseconds) start) 1000.0))
        (write-json
         (hasheq
          'campaign "bounded generic Edge load"
          'semantic_operations count
          'dedupe count
          'server_posts (first counts)
          'adapter_starts (third counts)
          'command_events event-count
          'elapsed_seconds elapsed
          'observed_operations_per_second (/ count elapsed)
          'peak_rss_kib (hash-ref memory "HWM" "unavailable")
          'final_rss_kib (hash-ref memory "RSS" "unavailable")
          'rebind_count 0
          'command_cache_high_water high-water
          'final_retained (metric-value f "retained")
          'queue_high_water "qualified separately by deterministic default-capacity tests"
          'qualification "host observations, not performance or service-level guarantees"))
        (newline))
      (lambda () (stop-edge-session! session))))))

(define (death-campaign count)
  (for ([n (in-range count)])
    (define first #f)
    (define second #f)
    (define session #f)
    (define replacement #f)
    (define point (list-ref '(idle admitted pending terminal stream-connected) (modulo n 5)))
    (dynamic-wind
     void
     (lambda ()
       (set! first (start-fixture "" (format "death-agent-a-~a" n) (new-directory)))
       (set! session (start-edge-session (fixture-client first) #:stale-ms 2000))
       (ensure (wait-until (lambda () (healthy session))) "snapshot before process death missing")
       (define old (attempt first (if (eq? point 'terminal) "success" "pending")))
       (unless (memq point '(idle stream-connected))
         (ensure
          (edge-response? (edge-submit-command (fixture-client first) old))
          "admission before death failed"))
       (when (memq point '(pending terminal))
         (ensure
          (wait-until
           (lambda ()
             (eq?
              (edge-command-state-phase (current-command (fixture-client first) old))
              (if (eq? point 'terminal) 'terminal 'executing))))
          "death point not observed"))
       (define previous (edge-session-current session))
       (subprocess-kill (fixture-process first) #t)
       (ensure (sync/timeout 2 (fixture-process first)) "killed process did not exit")
       (ensure
        (wait-until
         (lambda () (eq? (edge-session-state-health (edge-session-current session)) 'stale)))
        "process EOF did not stale session")
       (stop-edge-session! session)
       (stop-fixture first #f)
       ;; This temporary path belongs to the qualification harness, not server.
       (when (file-exists? (fixture-socket first))
         (delete-file (fixture-socket first)))
       (set! second (start-fixture "" (format "death-agent-b-~a" n) (fixture-directory first)))
       (define ended (box #f))
       (set!
        replacement
        (start-edge-session
         (fixture-client second)
         #:previous previous
         #:on-epoch-ended (lambda (id) (set-box! ended id))))
       (ensure (wait-until (lambda () (healthy replacement))) "replacement snapshot missing")
       (ensure
        (not
         (equal?
          (edge-session-state-agent-id previous)
          (edge-session-state-agent-id (edge-session-current replacement))))
        "agent ID reused")
       (ensure
        (equal? (unbox ended) (edge-session-state-agent-id previous))
        "old epoch not surfaced")
       (ensure (equal? (take (metrics second) 3) '("0" "0" "0")) "automatic replay on reconnect")
       ;; Caller deliberately tests old identity; rejection precedes adapter.
       (define rejected (edge-submit-command (fixture-client second) old))
       (ensure
        (and (edge-rejection? rejected) (= (edge-rejection-status rejected) 409))
        "old agent admitted")
       (ensure
        (equal? (take (metrics second) 3) '("1" "0" "0"))
        "old command produced replacement effect")
       (printf
        "controlled edge process-death cycle ~a/~a: ~a; fresh epoch; no automatic replay\n"
        (add1 n)
        count
        point))
     (lambda ()
       (when replacement
         (stop-edge-session! replacement))
       (when session
         (stop-edge-session! session))
       (when second
         (stop-fixture second))
       (when first
         (stop-fixture first))))))

(module+ main
  (match (vector->list (current-command-line-arguments))
    [(list (and mode (or "load" "death")) number)
     (define count (string->number number))
     (ensure
      (and (exact-positive-integer? count) (<= count 100000))
      "iteration count must be 1..100000")
     (define directory (make-temporary-file "m8-2-campaign-~a" 'directory))
     (define cust (make-custodian))
     (define result (make-channel))
     (dynamic-wind
      void
      (lambda ()
        (parameterize ([current-custodian cust]
                       [current-subprocess-custodian-mode 'kill]
                       [campaign-directory directory])
          (thread
           (lambda ()
             (define outcome
               (with-handlers ([exn:fail? values])
                 ((if (equal? mode "load") load-campaign death-campaign) count)
                 'passed))
             (channel-put result outcome))))
        (define outcome (sync/timeout (+ 60 (* count (if (equal? mode "load") .15 10))) result))
        (unless outcome
          (raise-user-error 'm8-2-process "campaign execution deadline exceeded"))
        (when (exn? outcome)
          (raise outcome)))
      (lambda ()
        (custodian-shutdown-all cust)
        (delete-directory/files directory)))]
    [_ (raise-user-error 'm8-2-process "expected load|death ITERATIONS")]))
