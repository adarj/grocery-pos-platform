#lang racket

(require (prefix-in db: db)
         racket/file
         rackunit
         "../pos/application/operator-service.rkt"
         "../pos/domain/operator-identity.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-operators.rkt")

(define fake-hash "$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA")

(define (append-test-audit! connection event)
  (append-security-audit-event!/in-transaction!
   connection event #:source-kind 'root_cli
   #:source-instance-id "audit_root_cli_test"
   #:occurred-at-epoch-ms 1000))

(define (call-with-operator-service procedure)
  (define connection (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (procedure
       connection
       (make-operator-service
        connection
        #:hash-pin (lambda (_pin) fake-hash)
        #:verify-pin (lambda (pin hash)
                       (and (string=? pin "80421637")
                            (string=? hash fake-hash))))))
    (lambda () (db:disconnect connection))))

(module+ test
  (test-case "failure after required operator audit insert rolls back row and sequence"
    (call-with-operator-service
     (lambda (connection ordinary)
       (define failing
         (make-operator-service
          connection
          #:audit-append!
          (lambda (writer event)
            (append-test-audit! writer event)
            (error 'test "failed after audit row insertion"))))
       (check-exn
        exn:fail?
        (lambda ()
          (operator-service-create
           failing "transient-operator" "Transient" 'cashier)))
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM operators") 0)
       (check-equal?
        (db:query-value connection "SELECT COUNT(*) FROM security_audit_events") 0)
       (check-pred
        operator-create-succeeded?
        (operator-service-create ordinary "durable-operator" "Durable" 'cashier))
       (check-equal?
        (db:query-list connection
                       "SELECT sequence FROM security_audit_events ORDER BY sequence")
        '(1))
       (check-true
        (security-audit-ledger-valid?
         (verify-security-audit-ledger connection))))))

  (test-case "required admin audit failure rolls back operator mutation"
    (call-with-operator-service
     (lambda (connection ordinary)
       (define failing
         (make-operator-service
          connection
          #:hash-pin (lambda (_pin) fake-hash)
          #:audit-append!
          (lambda (_connection _event)
            (error 'test "simulated audit append failure"))))
       (check-exn exn:fail?
                  (lambda ()
                    (operator-service-create
                     failing "rollback-operator" "Rollback" 'manager)))
       (check-equal?
        (db:query-value connection
                        "SELECT COUNT(*) FROM operators WHERE operator_id = 'rollback-operator'")
        0)
       (check-pred operator-create-succeeded?
                   (operator-service-create ordinary "existing" "Existing" 'cashier))
       (check-exn exn:fail?
                  (lambda ()
                    (operator-service-set-role failing "existing" 'manager)))
       (check-eq? (operator-identity-role
                   (operator-service-load ordinary "existing"))
                  'cashier)
       (check-exn exn:fail?
                  (lambda ()
                    (operator-service-set-active failing "existing" #f)))
       (check-true (operator-identity-active?
                    (operator-service-load ordinary "existing")))
       (check-exn exn:fail?
                  (lambda ()
                    (operator-service-enroll-pin failing "existing" "80421637")))
       (check-false (load-operator-pin-record connection "existing")))))

  (test-case "create list role and active updates expose only safe identity state"
    (call-with-operator-service
     (lambda (_connection service)
       (define created
         (operator-service-create service "Manager-A" "Ada" 'manager))
       (check-pred operator-create-succeeded? created)
       (check-pred operator-create-rejected?
                   (operator-service-create
                    service "Manager-A" "Duplicate" 'cashier))
       (define enrolled
         (operator-service-enroll-pin service "Manager-A" "80421637"))
       (check-pred operator-pin-enrollment-succeeded? enrolled)
       (check-equal?
        (operator-pin-enrollment-succeeded-credential-revision enrolled)
        1)
       (check-pred operator-update-succeeded?
                   (operator-service-set-role
                    service "Manager-A" 'supervisor))
       (check-pred operator-update-succeeded?
                   (operator-service-set-active service "Manager-A" #f))
       (define loaded (operator-service-load service "Manager-A"))
       (check-eq? (operator-identity-role loaded) 'supervisor)
       (check-false (operator-identity-active? loaded))
       (check-eq? (operator-identity-credential-state loaded) 'enrolled)
       (check-equal? (operator-identity-credential-revision loaded) 1)
       (check-false
        (for/or ([value (in-vector (struct->vector loaded))])
          (and (string? value) (string-contains? value "$argon2id$")))))))

  (test-case "enrollment hashes outside the writer and never overwrites"
    (call-with-operator-service
     (lambda (connection _service)
       (create-operator! connection "cashier" "Cashier" 'cashier
                         #:audit-append! append-test-audit!)
       (define service
         (make-operator-service
          connection
          #:hash-pin
          (lambda (_pin)
            (check-false (db:in-transaction? connection))
            fake-hash)
          #:verify-pin (lambda (_pin _hash) #t)))
       (check-pred
        operator-pin-enrollment-succeeded?
        (operator-service-enroll-pin service "cashier" "80421637"))
       (check-equal?
        (operator-pin-enrollment-rejected-code
         (operator-service-enroll-pin service "cashier" "80521637"))
        'credential-already-enrolled)
       (check-equal?
        (operator-pin-record-password-hash
         (load-operator-pin-record connection "cashier"))
        fake-hash))))

  (test-case "verification distinguishes missing inactive unenrolled and invalid"
    (call-with-operator-service
     (lambda (_connection service)
       (check-eq?
        (operator-pin-verification-code
         (operator-service-verify-pin service "missing" "80421637"))
        'operator-not-found)
       (operator-service-create service "unenrolled" "Unenrolled" 'cashier)
       (check-eq?
        (operator-pin-verification-code
         (operator-service-verify-pin service "unenrolled" "80421637"))
        'credential-enrollment-required)
       (operator-service-enroll-pin service "unenrolled" "80421637")
       (check-true
        (operator-pin-verification-verified?
         (operator-service-verify-pin service "unenrolled" "80421637")))
       (check-eq?
        (operator-pin-verification-code
         (operator-service-verify-pin service "unenrolled" "80421638"))
        'invalid-credential)
       (operator-service-set-active service "unenrolled" #f)
       (check-eq?
        (operator-pin-verification-code
         (operator-service-verify-pin service "unenrolled" "80421637"))
        'operator-inactive))))

  (test-case "concurrent same-ID operator creation has one winner"
    (define directory
      (make-temporary-file "operator-create-race-~a" 'directory))
    (define database-path (build-path directory "pos.db"))
    (define first-connection
      (open-pos-sqlite-connection database-path 'create))
    (migrate-pos-database! first-connection)
    (define second-connection
      (open-pos-sqlite-connection database-path 'read/write))
    (define start-gate (make-semaphore 0))
    (define results (make-channel))
    (define (start-create connection display-name)
      (thread
       (lambda ()
         (semaphore-wait start-gate)
         (channel-put
          results
          (with-handlers ([exn:fail? values])
            (operator-service-create
             (make-operator-service
              connection
              #:hash-pin (lambda (_pin) fake-hash)
              #:verify-pin (lambda (_pin _hash) #f))
             "same-id"
             display-name
             'cashier))))))
    (dynamic-wind
      (lambda ()
        (start-create first-connection "First")
        (start-create second-connection "Second")
        (semaphore-post start-gate)
        (semaphore-post start-gate))
      (lambda ()
        (define outcomes (list (channel-get results) (channel-get results)))
        (check-false (ormap exn:fail? outcomes))
        (check-equal? (count operator-create-succeeded? outcomes) 1)
        (check-equal? (count operator-create-rejected? outcomes) 1)
        (check-eq?
         (operator-create-rejected-code
          (findf operator-create-rejected? outcomes))
         'operator-already-exists)
        (check-equal? (length (list-operators first-connection)) 1))
      (lambda ()
        (db:disconnect second-connection)
        (db:disconnect first-connection)
        (delete-directory/files directory))))

  (test-case "concurrent initial enrollment has one winner"
    (define directory
      (make-temporary-file "operator-enrollment-race-~a" 'directory))
    (define database-path (build-path directory "pos.db"))
    (define first-connection
      (open-pos-sqlite-connection database-path 'create))
    (migrate-pos-database! first-connection)
    (create-operator! first-connection "race" "Race" 'cashier
                      #:audit-append! append-test-audit!)
    (define second-connection
      (open-pos-sqlite-connection database-path 'read/write))
    (define lock (make-semaphore 1))
    (define gate (make-semaphore 0))
    (define arrival-count 0)
    (define hash-held-writer? (box #f))
    (define (make-blocking-hasher connection hash)
      (lambda (_pin)
        (when (db:in-transaction? connection)
          (set-box! hash-held-writer? #t))
        (call-with-semaphore
         lock
         (lambda ()
           (set! arrival-count (add1 arrival-count))
           (when (= arrival-count 2)
             (semaphore-post gate)
             (semaphore-post gate))))
        (semaphore-wait gate)
        hash))
    (define results (make-channel))
    (define (start-enrollment connection hash pin)
      (thread
       (lambda ()
         (channel-put
         results
          (with-handlers ([exn:fail? values])
            (operator-service-enroll-pin
             (make-operator-service
              connection
              #:hash-pin (make-blocking-hasher connection hash)
              #:verify-pin (lambda (_pin _hash) #f))
             "race"
             pin))))))
    (dynamic-wind
      (lambda ()
        (start-enrollment first-connection
                          "$argon2id$v=19$m=19456,t=2,p=1$Zmlyc3Q$aGFzaA"
                          "80421637")
        (start-enrollment second-connection
                          "$argon2id$v=19$m=19456,t=2,p=1$c2Vjb25k$aGFzaA"
                          "80521637"))
      (lambda ()
        (define outcomes (list (channel-get results) (channel-get results)))
        (check-false (ormap exn:fail? outcomes))
        (check-false (unbox hash-held-writer?))
        (check-equal?
         (count operator-pin-enrollment-succeeded? outcomes)
         1)
        (check-equal?
         (count operator-pin-enrollment-rejected? outcomes)
         1)
        (check-eq?
         (operator-pin-enrollment-rejected-code
          (findf operator-pin-enrollment-rejected? outcomes))
         'credential-already-enrolled)
        (check-equal?
         (operator-pin-record-credential-revision
          (load-operator-pin-record first-connection "race"))
         1))
      (lambda ()
        (db:disconnect second-connection)
        (db:disconnect first-connection)
        (delete-directory/files directory)))))
