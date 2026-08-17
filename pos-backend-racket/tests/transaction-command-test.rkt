#lang racket

(require rackunit
         "../pos/application/transaction-command.rkt"
         "../pos/domain/money.rkt")

(module+ test
  (test-case "all current transaction commands carry immutable common identity"
    (define mutable-command-id (string-copy "cmd-001"))
    (define mutable-transaction-id (string-copy "txn-001"))
    (define mutable-barcode (string-copy "049000001234"))
    (define start
      (start-transaction-command mutable-command-id
                                 mutable-transaction-id
                                 0))
    (define scan
      (scan-barcode-command mutable-command-id
                            mutable-transaction-id
                            1
                            mutable-barcode))
    (define tender
      (tender-cash-command "cmd-002" "txn-001" 2 (money 500)))
    (define completion
      (complete-transaction-command "cmd-003" "txn-001" 3))

    (string-set! mutable-command-id 0 #\X)
    (string-set! mutable-transaction-id 0 #\X)
    (string-set! mutable-barcode 0 #\X)

    (for ([command (in-list (list start scan tender completion))])
      (check-pred transaction-command? command))
    (check-equal? (transaction-command-command-id start) "cmd-001")
    (check-equal? (transaction-command-transaction-id start) "txn-001")
    (check-equal? (transaction-command-expected-version start) 0)
    (check-equal? (scan-barcode-command-barcode scan) "049000001234")
    (check-equal? (tender-cash-command-amount tender) (money 500)))

  (test-case "independently constructed equivalent commands compare equal"
    (check-equal?
     (start-transaction-command "cmd-start" "txn-001" 0)
     (start-transaction-command "cmd-start" "txn-001" 0))
    (check-equal?
     (scan-barcode-command "cmd-scan" "txn-001" 1 "049000001234")
     (scan-barcode-command "cmd-scan" "txn-001" 1 "049000001234"))
    (check-equal?
     (tender-cash-command "cmd-tender" "txn-001" 2 (money 500))
     (tender-cash-command "cmd-tender" "txn-001" 2 (money 500)))
    (check-equal?
     (complete-transaction-command "cmd-complete" "txn-001" 3)
     (complete-transaction-command "cmd-complete" "txn-001" 3)))

  (test-case "any typed request difference changes command identity"
    (define scan
      (scan-barcode-command "cmd-001" "txn-001" 1 "049000001234"))

    (check-not-equal?
     scan
     (scan-barcode-command "cmd-001" "txn-002" 1 "049000001234"))
    (check-not-equal?
     scan
     (scan-barcode-command "cmd-001" "txn-001" 2 "049000001234"))
    (check-not-equal?
     (start-transaction-command "cmd-001" "txn-001" 1)
     (complete-transaction-command "cmd-001" "txn-001" 1))
    (check-not-equal?
     scan
     (scan-barcode-command "cmd-001" "txn-001" 1 "049000001235"))
    (check-not-equal?
     (tender-cash-command "cmd-001" "txn-001" 1 (money 500))
     (tender-cash-command "cmd-001" "txn-001" 1 (money 501))))

  (test-case "command constructors enforce application-boundary invariants"
    (for ([make-invalid
           (in-list
            (list
             (lambda () (start-transaction-command "" "txn-001" 0))
             (lambda () (start-transaction-command 1 "txn-001" 0))
             (lambda () (start-transaction-command "cmd-001" "" 0))
             (lambda () (start-transaction-command "cmd-001" 1 0))
             (lambda () (start-transaction-command "cmd-001" "txn-001" -1))
             (lambda () (start-transaction-command "cmd-001" "txn-001" 1.0))
             (lambda () (scan-barcode-command "cmd-001" "txn-001" 0 ""))
             (lambda () (scan-barcode-command "cmd-001" "txn-001" 0 490))
             (lambda () (tender-cash-command "cmd-001" "txn-001" 0 500))))])
      (check-exn exn:fail:contract? make-invalid))))
