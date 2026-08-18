#lang racket

(require rackunit
         "../pos/application/transaction-command-receipt.rkt"
         "../pos/application/transaction-command.rkt")

(module+ test
  (test-case "receipt preserves typed command and immutable outcome metadata"
    (define mutable-code (string-copy "unknown_barcode"))
    (define command
      (scan-barcode-command
       "cmd-scan" "txn-001" 1 "049000001234"))
    (define receipt
      (transaction-command-receipt
       command 'domain-rejected mutable-code 1))

    (string-set! mutable-code 0 #\X)

    (check-equal? (transaction-command-receipt-command receipt) command)
    (check-equal? (transaction-command-receipt-outcome-kind receipt)
                  'domain-rejected)
    (check-equal? (transaction-command-receipt-outcome-code receipt)
                  "unknown_barcode")
    (check-equal?
     (transaction-command-receipt-outcome-stream-version receipt)
     1))

  (test-case "receipt supports only the closed v1 outcome-kind categories"
    (for ([kind (in-list '(accepted
                           domain-rejected
                           not-found
                           already-exists
                           version-conflict))])
      (check-pred
       transaction-command-receipt?
       (transaction-command-receipt
        (start-transaction-command "cmd-start" "txn-001" 0)
        kind
        "stable_code"
        0))))

  (test-case "receipt constructor rejects malformed persistence values"
    (define command
      (start-transaction-command "cmd-start" "txn-001" 0))
    (for ([make-invalid
           (in-list
            (list
             (lambda ()
               (transaction-command-receipt
                'not-a-command 'accepted "accepted" 1))
             (lambda ()
               (transaction-command-receipt
                command 'future-kind "accepted" 1))
             (lambda ()
               (transaction-command-receipt command 'accepted "" 1))
             (lambda ()
               (transaction-command-receipt command 'accepted 'accepted 1))
             (lambda ()
               (transaction-command-receipt command 'accepted "accepted" -1))
             (lambda ()
               (transaction-command-receipt command 'accepted "accepted" 1.0))))])
      (check-exn exn:fail:contract? make-invalid))))
