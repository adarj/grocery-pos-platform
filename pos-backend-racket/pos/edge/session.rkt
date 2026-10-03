#lang racket/base

(require racket/match "protocol.rkt" "client.rkt")

(provide (struct-out edge-session-state)
         empty-edge-session-state
         edge-session-apply
         edge-session-reconnecting
         edge-session-estimated-uptime
         edge-session-healthy?
         start-edge-session
         stop-edge-session!
         edge-session?
         edge-session-current)

;; Immutable state replaces the entire snapshot/cache atomically. No GET result
;; writes this stream-derived cache. Uptime receipt and liveness have separate uses.
(struct edge-session-state
  (agent-id cursor devices health uptime received last-record failure)
  #:transparent)

(define (monotonic-ms)
  (inexact->exact (floor (current-inexact-monotonic-milliseconds))))

(define (empty-edge-session-state)
  (edge-session-state #f 0 (hash) 'waiting 0 0 0 #f))

(define (stale state code)
  (struct-copy edge-session-state state [health 'stale] [failure code]))

(define (edge-session-reconnecting state)
  (struct-copy edge-session-state state [health 'waiting] [failure #f]))

(define (snapshot-regresses? state snapshot)
  (and
   (equal? (edge-session-state-agent-id state) (edge-snapshot-event-agent-id snapshot))
   (or
    (< (edge-snapshot-event-cursor snapshot) (edge-session-state-cursor state))
    (for/or ([(id old) (in-hash (edge-session-state-devices state))])
      (define new
        (for/first ([d (in-list (edge-snapshot-event-devices snapshot))]
                    #:when (equal? id (edge-device-snapshot-device-id d)))
          d))
      (or
       (not new)
       (< (edge-device-snapshot-revision new) (edge-device-snapshot-revision old))
       (and
        (= (edge-device-snapshot-revision new) (edge-device-snapshot-revision old))
        (not (equal? new old))))))))

(define (edge-session-apply state event [local (monotonic-ms)])
  (define (fail code)
    (stale state code))

  (cond
    [(not (and (exact-integer? local) (>= local (edge-session-state-last-record state))))
     (fail 'monotonic-regression)]
    [(edge-snapshot-event? event)
     (cond
       [(not (eq? (edge-session-state-health state) 'waiting)) (fail 'unexpected-snapshot)]
       [(snapshot-regresses? state event) (fail 'snapshot-regression)]
       [(and
         (equal? (edge-session-state-agent-id state) (edge-snapshot-event-agent-id event))
         (< (edge-snapshot-event-uptime event) (edge-session-state-uptime state)))
        (fail 'uptime-regression)]
       [else
        (edge-session-state
         (edge-snapshot-event-agent-id event)
         (edge-snapshot-event-cursor event)
         (for/hash ([d (in-list (edge-snapshot-event-devices event))])
           (values (edge-device-snapshot-device-id d) d))
         'healthy
         (edge-snapshot-event-uptime event)
         local
         local
         #f)])]
    [(not (eq? (edge-session-state-health state) 'healthy)) (fail 'snapshot-required)]
    [else
     (define agent
       (cond
         [(edge-device-event? event) (edge-device-event-agent-id event)]
         [(edge-command-event? event) (edge-command-event-agent-id event)]
         [(edge-observation-event? event) (edge-observation-event-agent-id event)]
         [(edge-heartbeat? event) (edge-heartbeat-agent-id event)]
         [else #f]))
     (cond
       [(not (equal? agent (edge-session-state-agent-id state))) (fail 'agent-mismatch)]
       [(edge-heartbeat? event)
        (if (< (edge-heartbeat-uptime event) (edge-session-state-uptime state))
            (fail 'uptime-regression)
            (struct-copy
             edge-session-state
             state
             [uptime (edge-heartbeat-uptime event)]
             [received local]
             [last-record local]))]
       [else
        (define sequence
          (cond [(edge-device-event? event) (edge-device-event-sequence event)]
                [(edge-observation-event? event) (edge-observation-event-sequence event)]
                [else (edge-command-event-sequence event)]))
        (cond
          [(not (= sequence (add1 (edge-session-state-cursor state)))) (fail 'sequence-gap)]
          [(edge-observation-event? event)
           (define device
             (hash-ref (edge-session-state-devices state)
                       (edge-observation-event-device-id event) #f))
           (if (and device
                    (edge-scanner-barcode? (edge-observation-event-observation event))
                    (equal? (edge-device-snapshot-binding-id device)
                            (edge-observation-event-binding-id event))
                    (= (edge-device-snapshot-revision device)
                       (edge-observation-event-revision event))
                    (member "scanner.barcode" (edge-device-snapshot-capabilities device)))
               (struct-copy edge-session-state state [cursor sequence] [last-record local])
               (fail 'observation-state))]
          [(edge-device-event? event)
           (define device (edge-device-event-device event))
           (define old
             (hash-ref
              (edge-session-state-devices state)
              (edge-device-snapshot-device-id device)
              #f))
           (if (not
                (and
                 old
                 (=
                  (edge-device-snapshot-revision device)
                  (add1 (edge-device-snapshot-revision old)))))
               (fail 'revision-gap)
               (struct-copy
                edge-session-state
                state
                [cursor sequence]
                [last-record local]
                [devices
                 (hash-set
                  (edge-session-state-devices state)
                  (edge-device-snapshot-device-id device)
                  device)]))]
          [else (struct-copy edge-session-state state [cursor sequence] [last-record local])])])]))

(define (edge-session-estimated-uptime state [local (monotonic-ms)])
  (and
   (eq? (edge-session-state-health state) 'healthy)
   (>= local (edge-session-state-received state))
   (let ([estimated
          (+ (edge-session-state-uptime state) (- local (edge-session-state-received state)))])
     (and (edge-u64? estimated) estimated))))

(define (edge-session-healthy? state #:stale-ms [stale-ms 45000] #:now [now (monotonic-ms)])
  (and
   (eq? (edge-session-state-health state) 'healthy)
   (<= 0 (- now (edge-session-state-last-record state)) stale-ms)))

(struct edge-session (state-box custodian stream stopped))

(define (edge-session-current session)
  (unbox (edge-session-state-box session)))

;; Opt-in composition under the caller's current custodian. No MVP readiness,
;; database, checkout service, command resubmission, or automatic reconnect here.
(define (start-edge-session
         client
         #:previous [previous (empty-edge-session-state)]
         #:stale-ms [stale-ms 45000]
         #:on-command [on-command void]
         #:on-observation [on-observation void]
         #:on-epoch-ended [on-epoch-ended void])
  (unless (and (exact-integer? stale-ms) (positive? stale-ms))
    (raise-argument-error 'start-edge-session "positive stale milliseconds" stale-ms))
  (define cust (make-custodian))
  (define state (box (edge-session-reconnecting previous)))
  (define stream-box (box #f))
  (define stopped (box #f))
  (define session (edge-session state cust stream-box stopped))
  (define (deliver-observation event)
    (define returned? #f)
    (dynamic-wind
     void
     (lambda ()
       ;; Racket can raise arbitrary values, not just exn:fail?. Never retain or
       ;; print callback payloads. A barrier prevents later continuation reentry.
       (with-handlers ([(lambda (_) #t)
                        (lambda (_)
                          (raise (exn:fail:edge-protocol
                                  "Edge observation callback failed"
                                  (current-continuation-marks)
                                  'observation-callback)))])
         ;; The default abort protocol carries an arbitrary thunk. Intercept it
         ;; here: invoking it outside this boundary could print private data.
         (call-with-continuation-prompt
          (lambda () (call-with-continuation-barrier (lambda () (on-observation event))))
          (default-continuation-prompt-tag)
          (lambda _
            (raise (exn:fail:edge-protocol
                    "Edge observation callback failed"
                    (current-continuation-marks)
                    'observation-callback))))
         (set! returned? #t)))
     (lambda ()
       ;; A nonlocal escape closes the stream through the outer dynamic-wind.
       ;; It must not leave its committed cursor marked healthy. Self-stop kills
       ;; the callback's custodian; preserve the deliberately published stopped
       ;; state in that case rather than overwriting it as a callback failure.
       (unless (or returned? (unbox stopped))
         (set-box! state (stale (unbox state) 'observation-callback))))))
  (parameterize ([current-custodian cust])
    (thread
     (lambda ()
       (with-handlers ([exn:fail:edge-protocol?
                        (lambda (e)
                          (set-box! state (stale (unbox state) (exn:fail:edge-protocol-code e))))]
                       [exn:fail? (lambda (_) (set-box! state (stale (unbox state) 'transport)))])
         (define stream (edge-open-events client))
         (cond
           [(not (edge-stream? stream)) (set-box! state (stale (unbox state) 'open-failed))]
           [else
            (set-box! stream-box stream)
            (dynamic-wind
             void
             (lambda ()
               (let loop ()
                 (define result (make-channel))
                 (define reader
                   (thread
                    (lambda ()
                      (with-handlers ([exn:fail? (lambda (e) (channel-put result e))])
                        (channel-put result (read-edge-record (edge-stream-input stream)))))))
                 (define record (sync/timeout (/ stale-ms 1000) result))
                 (cond
                   [(not record)
                    (kill-thread reader)
                    (set-box! state (stale (unbox state) 'heartbeat-timeout))]
                   [(exn? record) (raise record)]
                   [(eof-object? record) (set-box! state (stale (unbox state) 'eof))]
                   [else
                    (define event (parse-edge-event (decode-edge-json record)))
                    (define old (unbox state))
                    (define next (edge-session-apply old event))
                    (set-box! state next)
                    (when (eq? (edge-session-state-health next) 'healthy)
                      (when (and
                             (edge-snapshot-event? event)
                             (edge-session-state-agent-id old)
                             (not
                              (equal?
                               (edge-session-state-agent-id old)
                               (edge-session-state-agent-id next))))
                        (on-epoch-ended (edge-session-state-agent-id old)))
                      (when (edge-command-event? event)
                        (on-command (edge-command-event-command event)))
                      (when (edge-observation-event? event)
                        (deliver-observation event))
                      (loop))])))
             (lambda ()
               (close-edge-stream! stream)
               (set-box! stream-box #f)))])))))
  session)

(define (stop-edge-session! session)
  (unless (unbox (edge-session-stopped session))
    (set-box! (edge-session-stopped session) #t)

    (define (mark-stopped!)
      (set-box!
       (edge-session-state-box session)
       (stale (unbox (edge-session-state-box session)) 'stopped)))
    ;; A callback runs inside this custodian: shutdown can kill its caller and
    ;; never return. Publish stale state before that point, then repeat after an
    ;; external shutdown to win any last reader update racing with stop.
    (mark-stopped!)
    (define stream (unbox (edge-session-stream session)))
    (when stream
      (close-edge-stream! stream))
    (custodian-shutdown-all (edge-session-custodian session))
    (mark-stopped!)))
