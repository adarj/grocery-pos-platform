#lang racket

(require rackunit
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/fake-catalog.rkt"
         "../pos/domain/money.rkt")

(module+ test
  (test-case "known barcode returns its canonical catalog item"
    (define item (fake-catalog-lookup "049000001234"))

    (check-pred catalog-item? item)
    (check-equal? (catalog-item-barcode item) "049000001234")
    (check-equal? (catalog-item-description item) "Test Apples")
    (check-equal? (catalog-item-unit-price item) (money 199)))

  (test-case "unknown barcode returns false"
    (check-false (fake-catalog-lookup "000000000000")))

  (test-case "catalog lookup requires a string barcode"
    (check-exn exn:fail:contract?
               (lambda () (fake-catalog-lookup 49000001234)))))
