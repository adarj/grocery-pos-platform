#lang racket

(require db
         rackunit
         racket/file
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-auth-throttle.rkt")

(define (call-with-test-database procedure)
  (define path (make-temporary-file "pos-auth-throttle-~a.sqlite"))
  (delete-file path)
  (dynamic-wind
    void
    (lambda ()
      (define connection (sqlite3-connect #:database path #:mode 'create))
      (query-exec connection "PRAGMA foreign_keys = ON")
      (migrate-pos-database! connection)
      (query-exec connection "INSERT INTO operators VALUES ('known', 'Known', 1)")
      (query-exec connection "INSERT INTO operator_roles VALUES ('known', 'cashier')")
      (procedure path connection)
      (disconnect connection))
    (lambda ()
      (when (file-exists? path) (delete-file path)))))

(module+ test
  (test-case "failure progression uses the frozen delay schedule"
    (call-with-test-database
     (lambda (_path connection)
       (for ([expected-count (in-range 1 9)]
             [expected-delay (in-list '(0 0 0 5000 15000 30000 60000 60000))])
         (define now (* expected-count 100000))
         (define state (record-operator-login-failure! connection "known" now))
         (check-equal? (operator-login-throttle-consecutive-failures state)
                       expected-count)
         (check-equal? (operator-login-throttle-last-failed-at-epoch-ms state)
                       now)
         (check-equal? (operator-login-throttle-blocked-until-epoch-ms state)
                       (+ now expected-delay))))))

  (test-case "blocked attempts do not increment or extend durable state"
    (call-with-test-database
     (lambda (_path connection)
       (for ([now (in-list '(0 1 2 3))])
         (record-operator-login-failure! connection "known" now))
       (define before (load-operator-login-throttle connection "known"))
       (check-true (operator-login-throttle-blocked? before 1000))
       (define during
         (record-operator-login-failure! connection "known" 1000))
       (check-equal? during before)
       (check-equal? (load-operator-login-throttle connection "known") before))))

  (test-case "fifteen quiet minutes reset the next failure sequence"
    (call-with-test-database
     (lambda (_path connection)
       (record-operator-login-failure! connection "known" 100)
       (define state
         (record-operator-login-failure!
          connection "known" (+ 100 operator-login-throttle-reset-after-ms)))
       (check-equal? (operator-login-throttle-consecutive-failures state) 1)
       (check-equal? (operator-login-throttle-blocked-until-epoch-ms state)
                     (+ 100 operator-login-throttle-reset-after-ms)))))

  (test-case "wall-clock rollback does not block no-delay failure tiers"
    (call-with-test-database
     (lambda (_path connection)
       (define first
         (record-operator-login-failure! connection "known" 1000000))
       (check-false (operator-login-throttle-blocked? first 500000))
       (define second
         (record-operator-login-failure! connection "known" 500000))
       (check-equal?
        (operator-login-throttle-consecutive-failures second) 2)
       (check-false (operator-login-throttle-blocked? second 400000)))))

  (test-case "wall-clock rollback cannot trigger the quiet-period reset"
    (call-with-test-database
     (lambda (_path connection)
       (record-operator-login-failure! connection "known" 1000000)
       (define after-rollback
         (record-operator-login-failure! connection "known" 1000))
       (check-equal?
        (operator-login-throttle-consecutive-failures after-rollback) 2)
       (check-equal?
        (operator-login-throttle-last-failed-at-epoch-ms after-rollback)
        1000000)
       (define before-quiet-period
         (record-operator-login-failure!
          connection
          "known"
          (+ 1000000 (sub1 operator-login-throttle-reset-after-ms))))
       (check-equal?
        (operator-login-throttle-consecutive-failures before-quiet-period)
        3))))

  (test-case "success clears state and state survives connection reconstruction"
    (call-with-test-database
     (lambda (path connection)
       (record-operator-login-failure! connection "known" 10)
       (disconnect connection)
       (define reopened (sqlite3-connect #:database path #:mode 'read/write))
       (check-equal?
        (operator-login-throttle-consecutive-failures
         (load-operator-login-throttle reopened "known"))
        1)
       (clear-operator-login-throttle! reopened "known")
       (check-false (load-operator-login-throttle reopened "known"))
       (disconnect reopened))))

  (test-case "unknown operators never create durable throttle rows"
    (call-with-test-database
     (lambda (_path connection)
       (check-false
        (record-operator-login-failure! connection "unknown" 100))
       (check-equal?
        (query-value connection "SELECT COUNT(*) FROM operator_login_throttle")
        0)))))
