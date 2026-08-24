#lang racket

(require "money.rkt")

(provide (struct-out shift-cash-summary)
         (struct-out shift-cash-summary-found)
         (struct-out shift-cash-summary-not-found)
         (struct-out shift-cash-summary-unavailable))

(define (non-empty-string? value)
  (and (string? value) (positive? (string-length value))))

(struct shift-cash-summary
  (shift-id
   status
   opening-cash
   completed-cash-sale-count
   cash-sales
   expected-cash
   counted-cash
   over-short-minor-units)
  #:transparent
  #:guard
  (lambda (shift-id
           status
           opening-cash
           completed-cash-sale-count
           cash-sales
           expected-cash
           counted-cash
           over-short-minor-units
           type-name)
    (unless (non-empty-string? shift-id)
      (raise-argument-error type-name "non-empty-string?" shift-id))
    (unless (memq status '(open closed))
      (raise-argument-error type-name "(or/c 'open 'closed)" status))
    (for ([value (in-list (list opening-cash cash-sales expected-cash))]
          [field-name (in-list '(opening-cash cash-sales expected-cash))])
      (unless (money? value)
        (raise-arguments-error
         type-name
         "nonnegative cash values must use exact money"
         (symbol->string field-name)
         value)))
    (unless (and (exact-integer? completed-cash-sale-count)
                 (>= completed-cash-sale-count 0))
      (raise-argument-error
       type-name "exact-nonnegative-integer?" completed-cash-sale-count))
    (unless
        (= (money-minor-units expected-cash)
           (+ (money-minor-units opening-cash)
              (money-minor-units cash-sales)))
      (raise-arguments-error
       type-name
       "expected cash must equal opening cash plus completed cash sales"
       "opening cash" opening-cash
       "cash sales" cash-sales
       "expected cash" expected-cash))
    (case status
      [(open)
       (unless (and (not counted-cash) (not over-short-minor-units))
         (raise-arguments-error
          type-name
          "an open shift cannot have counted cash or over/short"
          "counted cash" counted-cash
          "over/short" over-short-minor-units))]
      [(closed)
       (unless (money? counted-cash)
         (raise-argument-error type-name "money?" counted-cash))
       (unless (exact-integer? over-short-minor-units)
         (raise-argument-error
          type-name "exact-integer?" over-short-minor-units))
       (unless
           (= over-short-minor-units
              (- (money-minor-units counted-cash)
                 (money-minor-units expected-cash)))
         (raise-arguments-error
          type-name
          "over/short must equal counted cash minus expected cash"
          "counted cash" counted-cash
          "expected cash" expected-cash
          "over/short" over-short-minor-units))])
    (values (string->immutable-string shift-id)
            status
            opening-cash
            completed-cash-sale-count
            cash-sales
            expected-cash
            counted-cash
            over-short-minor-units)))

(struct shift-cash-summary-found (summary)
  #:transparent
  #:guard
  (lambda (summary type-name)
    (unless (shift-cash-summary? summary)
      (raise-argument-error type-name "shift-cash-summary?" summary))
    summary))

(struct shift-cash-summary-not-found (shift-id) #:transparent)
(struct shift-cash-summary-unavailable (shift-id) #:transparent)
