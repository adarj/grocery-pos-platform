#lang racket

(require db
         racket/file
         rackunit
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/domain/security-audit-event.rkt"
         "../pos/persistence/security-audit-event-codec.rkt"
         "../pos/persistence/security-audit-store.rkt"
         "../pos/persistence/sqlite-connection.rkt"
         "../pos/persistence/sqlite-maintenance.rkt"
         "../pos/persistence/sqlite-transaction-event-store.rkt"
         (only-in "../pos/domain/transaction.rkt" replay-transaction)
         "../pos/domain/transaction-event.rkt"
         "../pos/runtime.rkt")

(define (with-database procedure)
  (define connection (sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (procedure connection))
    (lambda () (disconnect connection))))

(module+ test
  (test-case "transaction journal loading does not consult security audit rows"
    (with-database
     (lambda (connection)
       (check-true
        (journal-append-succeeded?
         (append-transaction-events!
          connection "txn-audit-independent" 0
          (list (transaction-started "txn-audit-independent")))))
       (define before
         (load-transaction-events connection "txn-audit-independent"))
       (check-true (journal-load-succeeded? before))
       ;; Deliberately damage only this isolated audit fixture. Business
       ;; replay remains a journal concern, while startup validation fails.
       (query-exec connection "DROP TRIGGER security_audit_events_append_order")
       (query-exec connection "DROP TRIGGER security_audit_events_no_update")
       (query-exec connection "DROP TRIGGER security_audit_events_no_delete")
       (query-exec connection "DROP TABLE security_audit_events")
       (define after
         (load-transaction-events connection "txn-audit-independent"))
       (check-true (journal-load-succeeded? after))
       (check-equal? (journal-load-succeeded-events after)
                     (journal-load-succeeded-events before))
       (check-equal?
        (replay-transaction (journal-load-succeeded-events after))
        (replay-transaction (journal-load-succeeded-events before))))))

  (test-case "event codec accepts only fixed typed fields and supported values"
    (check-equal?
     (security-audit-event->json
      (operator-created-event "Alice" 'cashier))
     "{\"operator_id\":\"Alice\",\"role\":\"cashier\"}")
    (for ([text
           (in-list
            '("{\"operator_id\":\"Alice\",\"role\":\"cashier\",\"pin\":\"80421637\"}"
              "{\"operator_id\":\"Alice\",\"role\":\"owner\"}"
              "{\"operator_id\":\"Alice\",\"role\":\"cashier\",\"role\":\"manager\"}"
              "{\"operator_id\":123,\"role\":\"cashier\"}"))])
      (check-exn exn:fail?
                 (lambda ()
                   (decode-security-audit-event-json 'operator.created text))))
    (check-exn exn:fail?
               (lambda ()
                 (decode-security-audit-event-json
                  'unknown.security_event "{}"))))

  (test-case "validated backup preserves the exact audit chain"
    (define directory
      (make-temporary-file "grocery-pos-audit-backup-~a" 'directory))
    (define source-path (build-path directory "pos.db"))
    (define backup-path (build-path directory "pos-backup.db"))
    (dynamic-wind
      void
      (lambda ()
        (initialize-sqlite-database! source-path)
        (define live
          (open-pos-sqlite-connection source-path 'read/write))
        (define hashes
          (dynamic-wind
            void
            (lambda ()
              (append-security-audit-event!
               live (runtime-started-event)
               #:source-kind 'pos_core
               #:source-instance-id "audit_runtime_backup"
               #:occurred-at-epoch-ms 100)
              (append-security-audit-event!
               live (login-failed-event #f)
               #:source-kind 'pos_core
               #:source-instance-id "audit_runtime_backup"
               #:occurred-at-epoch-ms 99)
              (query-rows live
                          "SELECT sequence, event_json, previous_event_hash, event_hash FROM security_audit_events ORDER BY sequence"))
            (lambda () (disconnect live))))
        (define created (create-pos-sqlite-backup! source-path backup-path))
        (check-true
         (sqlite-backup-validation-valid?
          (sqlite-backup-created-validation created)))
        (call-with-pos-sqlite-inspection-connection
         backup-path
         (lambda (backup)
           (check-equal?
            (query-rows backup
                        "SELECT sequence, event_json, previous_event_hash, event_hash FROM security_audit_events ORDER BY sequence")
            hashes)
           (check-true
            (security-audit-ledger-valid?
             (verify-security-audit-ledger backup)))))
        (define damaged-backup
          (sqlite3-connect #:database backup-path #:mode 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (query-exec damaged-backup
                        "DROP TRIGGER security_audit_events_no_update")
            (query-exec damaged-backup
                        "UPDATE security_audit_events SET occurred_at_epoch_ms = 101 WHERE sequence = 1"))
          (lambda () (disconnect damaged-backup)))
        (check-false
         (sqlite-backup-validation-valid?
          (validate-pos-sqlite-backup backup-path))))
      (lambda () (delete-directory/files directory))))

  (test-case "concurrent file-backed writers allocate one contiguous chain"
    (define directory
      (make-temporary-file "grocery-pos-audit-writers-~a" 'directory))
    (define database-path (build-path directory "pos.db"))
    (dynamic-wind
      void
      (lambda ()
        (initialize-sqlite-database! database-path)
        (define start (make-semaphore 0))
        (define results (make-channel))
        (define writers
          (for/list ([writer-id (in-range 2)])
            (thread
             (lambda ()
               (with-handlers ([exn:fail?
                                (lambda (exception)
                                  (channel-put results exception))])
                 (define connection
                   (open-pos-sqlite-connection database-path 'read/write))
                 (dynamic-wind
                   void
                   (lambda ()
                     (semaphore-wait start)
                     (for ([index (in-range 10)])
                       (append-security-audit-event!
                        connection (runtime-started-event)
                        #:source-kind 'pos_core
                        #:source-instance-id (format "writer-~a" writer-id)
                        #:occurred-at-epoch-ms index))
                     (channel-put results #t))
                   (lambda () (disconnect connection))))))))
        (for ([_ (in-list writers)]) (semaphore-post start))
        (for ([_ (in-list writers)])
          (define result (channel-get results))
          (when (exn:fail? result) (raise result))
          (check-true result))
        (define reader
          (open-pos-sqlite-connection database-path 'read/write))
        (dynamic-wind
          void
          (lambda ()
            (check-equal?
             (query-list reader
                         "SELECT sequence FROM security_audit_events ORDER BY sequence")
             (build-list 20 add1))
            (define verified (verify-security-audit-ledger reader))
            (check-true (security-audit-ledger-valid? verified))
            (check-equal? (security-audit-ledger-valid-event-count verified) 20))
          (lambda () (disconnect reader))))
      (lambda () (delete-directory/files directory))))

  (test-case "chain verification detects payload, metadata, linkage, and sequence corruption"
    (for ([damage!
           (in-list
            (list
             (lambda (c) (query-exec c "UPDATE security_audit_events SET event_type = 'auth.login_failed' WHERE sequence = 2"))
             (lambda (c) (query-exec c "UPDATE security_audit_events SET event_json = '{\"bad\":1}' WHERE sequence = 2"))
             (lambda (c) (query-exec c "UPDATE security_audit_events SET occurred_at_epoch_ms = 999 WHERE sequence = 2"))
             (lambda (c) (query-exec c "UPDATE security_audit_events SET source_instance_id = 'other-runtime' WHERE sequence = 2"))
             (lambda (c) (query-exec c "UPDATE security_audit_events SET source_kind = 'root_cli' WHERE sequence = 2"))
             (lambda (c) (query-exec c "UPDATE security_audit_events SET previous_event_hash = zeroblob(32) WHERE sequence = 2"))
             (lambda (c) (query-exec c "UPDATE security_audit_events SET event_hash = zeroblob(32) WHERE sequence = 2"))
             (lambda (c) (query-exec c "DELETE FROM security_audit_events WHERE sequence = 2"))
             (lambda (c) (query-exec c "UPDATE security_audit_events SET sequence = 4 WHERE sequence = 3"))
             (lambda (c)
               (query-exec c
                           "UPDATE security_audit_events SET occurred_at_epoch_ms = CASE sequence WHEN 1 THEN 300 WHEN 3 THEN 100 ELSE occurred_at_epoch_ms END WHERE sequence IN (1, 3)"))))])
      (with-database
       (lambda (connection)
         (for ([epoch '(100 200 300)])
           (append-security-audit-event!
            connection (runtime-started-event)
            #:source-kind 'pos_core
            #:source-instance-id "audit_runtime_test"
            #:occurred-at-epoch-ms epoch))
         (query-exec connection "DROP TRIGGER security_audit_events_no_update")
         (query-exec connection "DROP TRIGGER security_audit_events_no_delete")
         (damage! connection)
         (check-true (security-audit-ledger-invalid?
                      (verify-security-audit-ledger connection)))))))

  (test-case "current-schema validation rejects any missing audit trigger"
    (for ([name (in-list '("security_audit_events_append_order"
                            "security_audit_events_no_update"
                            "security_audit_events_no_delete"))])
      (with-database
       (lambda (connection)
         (query-exec connection (format "DROP TRIGGER ~a" name))
         (check-exn exn:fail?
                    (lambda ()
                      (validate-pos-database-schema!
                       connection #:require-current? #t)))))))

  (test-case "v11 starts empty and rejects mutation or out-of-order insert"
    (with-database
     (lambda (connection)
       (check-equal? current-pos-database-schema-version 11)
       (check-equal?
        (query-value connection "SELECT COUNT(*) FROM security_audit_events")
        0)
       (define event (runtime-started-event))
       (append-security-audit-event! connection event
                                     #:source-kind 'pos_core
                                     #:source-instance-id "audit_runtime_test"
                                     #:occurred-at-epoch-ms 123)
       (check-exn exn:fail?
                  (lambda ()
                    (query-exec connection
                                "UPDATE security_audit_events SET occurred_at_epoch_ms = 124 WHERE sequence = 1")))
       (check-exn exn:fail?
                  (lambda ()
                    (query-exec connection
                                "DELETE FROM security_audit_events WHERE sequence = 1")))
       (check-exn exn:fail?
                  (lambda ()
                    (query-exec connection
                                (string-append
                                 "INSERT INTO security_audit_events "
                                 "SELECT 3, schema_version, occurred_at_epoch_ms, "
                                 "source_kind, source_instance_id, event_type, event_json, "
                                 "previous_event_hash, event_hash FROM security_audit_events WHERE sequence = 1"))))
       (check-true (security-audit-ledger-valid?
                    (verify-security-audit-ledger connection))))))

  (test-case "triggers enforce structure while application verification rejects bogus hashes"
    (with-database
     (lambda (connection)
       (append-security-audit-event!
        connection (runtime-started-event)
        #:source-kind 'pos_core
        #:source-instance-id "audit_runtime_trigger_test"
        #:occurred-at-epoch-ms 100)
       (define (direct-insert sequence previous-expression)
         (query-exec
          connection
          (format
           (string-append
            "INSERT INTO security_audit_events "
            "SELECT ~a, schema_version, occurred_at_epoch_ms, source_kind, "
            "source_instance_id, event_type, event_json, ~a, randomblob(32) "
            "FROM security_audit_events WHERE sequence = 1")
           sequence previous-expression)))
       (check-exn exn:fail? (lambda () (direct-insert 1 "event_hash")))
       (check-exn exn:fail? (lambda () (direct-insert 3 "event_hash")))
       (check-exn exn:fail? (lambda () (direct-insert 2 "zeroblob(32)")))
       ;; SQLite does not recompute SHA-256. A structurally linked but forged
       ;; hash is accepted by the triggers and then rejected by the verifier.
       (direct-insert 2 "event_hash")
       (check-true
        (security-audit-ledger-invalid?
         (verify-security-audit-ledger connection)))
       (check-exn
        exn:fail?
        (lambda ()
          (validate-pos-database-schema! connection #:require-current? #t))))))

  (test-case "events chain and a rolled-back append leaves no gap"
    (with-database
     (lambda (connection)
       (append-security-audit-event! connection (runtime-started-event)
                                     #:source-kind 'pos_core
                                     #:source-instance-id "audit_runtime_test"
                                     #:occurred-at-epoch-ms 123)
       (check-exn exn:fail?
                  (lambda ()
                    (call-with-transaction
                     connection
                     (lambda ()
                       (append-security-audit-event!/in-transaction!
                        connection (runtime-started-event)
                        #:source-kind 'pos_core
                        #:source-instance-id "audit_runtime_test"
                        #:occurred-at-epoch-ms 124)
                       (error 'test "rollback"))
                     #:option 'immediate)))
       (append-security-audit-event! connection (runtime-started-event)
                                     #:source-kind 'pos_core
                                     #:source-instance-id "audit_runtime_test"
                                     #:occurred-at-epoch-ms 125)
       (check-equal?
        (query-list connection "SELECT sequence FROM security_audit_events ORDER BY sequence")
        '(1 2))
       (check-true (security-audit-ledger-valid?
                    (verify-security-audit-ledger connection)))))))
