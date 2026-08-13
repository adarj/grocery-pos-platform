#lang racket

(require rackunit
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/money.rkt")

(module+ test
  (test-case "catalog item owns immutable copies of textual facts"
    (define source-barcode (string-copy "049000001234"))
    (define source-description (string-copy "Test Apples"))
    (define item
      (catalog-item source-barcode source-description (money 199)))

    (string-set! source-barcode 0 #\9)
    (string-set! source-description 0 #\B)

    (check-equal? (catalog-item-barcode item) "049000001234")
    (check-equal? (catalog-item-description item) "Test Apples")
    (check-true (immutable? (catalog-item-barcode item)))
    (check-true (immutable? (catalog-item-description item)))))
