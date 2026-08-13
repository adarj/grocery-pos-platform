#lang racket

(require "catalog-item.rkt"
         "money.rkt")

(provide fake-catalog-lookup)

(define items-by-barcode
  (hash "049000001234"
        (catalog-item "049000001234"
                      "Test Apples"
                      (money 199))))

(define (fake-catalog-lookup barcode)
  (unless (string? barcode)
    (raise-argument-error 'fake-catalog-lookup "string?" barcode))
  (hash-ref items-by-barcode barcode #f))
