#lang racket

(require (prefix-in db: db))

(provide operator-login-throttle-reset-after-ms
         (struct-out operator-login-throttle)
         operator-login-throttle-blocked?
         load-operator-login-throttle
         record-operator-login-failure!
         clear-operator-login-throttle!)

(define operator-login-throttle-reset-after-ms (* 15 60 1000))

(struct operator-login-throttle
  (operator-id
   consecutive-failures
   last-failed-at-epoch-ms
   blocked-until-epoch-ms)
  #:transparent)

(define (check-connection who connection)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection)))

(define (check-operator-id who operator-id)
  (unless (and (string? operator-id) (positive? (string-length operator-id)))
    (raise-argument-error who "non-empty-string?" operator-id)))

(define (check-epoch-ms who epoch-ms)
  (unless (and (exact-integer? epoch-ms) (>= epoch-ms 0))
    (raise-argument-error who "exact-nonnegative-integer?" epoch-ms)))

(define (row->operator-login-throttle row)
  (and row
       (operator-login-throttle
        (vector-ref row 0)
        (vector-ref row 1)
        (vector-ref row 2)
        (vector-ref row 3))))

(define (load-operator-login-throttle connection operator-id)
  (check-connection 'load-operator-login-throttle connection)
  (check-operator-id 'load-operator-login-throttle operator-id)
  (row->operator-login-throttle
   (db:query-maybe-row
    connection
    #<<SQL
SELECT operator_id, consecutive_failures, last_failed_at_epoch_ms,
       blocked_until_epoch_ms
FROM operator_login_throttle
WHERE operator_id = ?
SQL
    operator-id)))

(define (operator-login-throttle-blocked? state now-epoch-ms)
  (unless (operator-login-throttle? state)
    (raise-argument-error
     'operator-login-throttle-blocked? "operator-login-throttle?" state))
  (check-epoch-ms 'operator-login-throttle-blocked? now-epoch-ms)
  (and (>= (operator-login-throttle-consecutive-failures state) 4)
       (< now-epoch-ms
          (operator-login-throttle-blocked-until-epoch-ms state))))

(define (failure-delay-ms failure-count)
  (cond
    [(<= failure-count 3) 0]
    [(= failure-count 4) 5000]
    [(= failure-count 5) 15000]
    [(= failure-count 6) 30000]
    [else 60000]))

(define (record-operator-login-failure! connection operator-id now-epoch-ms)
  (check-connection 'record-operator-login-failure! connection)
  (check-operator-id 'record-operator-login-failure! operator-id)
  (check-epoch-ms 'record-operator-login-failure! now-epoch-ms)
  (db:call-with-transaction
   connection
   (lambda ()
     ;; Unknown IDs never create durable rows: this prevents unauthenticated
     ;; input from growing the authoritative database without bound.
     (cond
       [(not (db:query-maybe-value
              connection
              "SELECT 1 FROM operators WHERE operator_id = ?"
              operator-id))
        #f]
       [else
        (define existing
          (load-operator-login-throttle connection operator-id))
        (cond
          [(and existing
                (operator-login-throttle-blocked? existing now-epoch-ms))
           existing]
          [else
           (define quiet-reset?
             (and existing
                  (>= now-epoch-ms
                      (operator-login-throttle-last-failed-at-epoch-ms
                       existing))
                  (>= (- now-epoch-ms
                         (operator-login-throttle-last-failed-at-epoch-ms
                          existing))
                      operator-login-throttle-reset-after-ms)))
           (define next-count
             (if (or (not existing) quiet-reset?)
                 1
                 (add1
                  (operator-login-throttle-consecutive-failures existing))))
           ;; Never move the durable observation backward. Otherwise a later
           ;; wall-clock correction could make the quiet period appear to have
           ;; elapsed since a failure that actually happened more recently.
           (define effective-failed-at
             (if existing
                 (max now-epoch-ms
                      (operator-login-throttle-last-failed-at-epoch-ms
                       existing))
                 now-epoch-ms))
           (define blocked-until
             (+ effective-failed-at (failure-delay-ms next-count)))
           (db:query-exec
            connection
            #<<SQL
INSERT INTO operator_login_throttle
  (operator_id, consecutive_failures, last_failed_at_epoch_ms,
   blocked_until_epoch_ms)
VALUES (?, ?, ?, ?)
ON CONFLICT(operator_id) DO UPDATE SET
  consecutive_failures = excluded.consecutive_failures,
  last_failed_at_epoch_ms = excluded.last_failed_at_epoch_ms,
  blocked_until_epoch_ms = excluded.blocked_until_epoch_ms
SQL
            operator-id next-count effective-failed-at blocked-until)
           (operator-login-throttle
            operator-id next-count effective-failed-at blocked-until)])]))
   #:option 'immediate))

(define (clear-operator-login-throttle! connection operator-id)
  (check-connection 'clear-operator-login-throttle! connection)
  (check-operator-id 'clear-operator-login-throttle! operator-id)
  (db:query-exec
   connection
   "DELETE FROM operator_login_throttle WHERE operator_id = ?"
   operator-id)
  (void))
