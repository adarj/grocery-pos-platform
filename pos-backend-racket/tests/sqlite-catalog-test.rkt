#lang racket

(require (prefix-in db: db)
         rackunit
         "../pos/domain/catalog-item.rkt"
         "../pos/domain/money.rkt"
         "../pos/domain/tax.rkt"
         "../pos/persistence/pos-database-migrations.rkt"
         "../pos/persistence/sqlite-catalog.rkt")

(define (call-with-catalog procedure)
  (define connection
    (db:sqlite3-connect #:database 'memory))
  (dynamic-wind
    void
    (lambda ()
      (migrate-pos-database! connection)
      (procedure connection))
    (lambda () (db:disconnect connection))))

(define (insert-item! connection item-id description price active)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO catalog_items
  (item_id, description, unit_price_minor_units, active)
VALUES (?, ?, ?, ?)
SQL
   item-id description price active)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO catalog_item_tax_categories (item_id, tax_category_id)
VALUES (?, '__legacy_zero_tax__')
SQL
   item-id))

(define (insert-tax-category! connection category-id description rate)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO tax_categories (tax_category_id, description, rate_millionths)
VALUES (?, ?, ?)
SQL
   category-id description rate))

(define (set-item-tax-category! connection item-id category-id)
  (db:query-exec
   connection
   #<<SQL
UPDATE catalog_item_tax_categories
SET tax_category_id = ?
WHERE item_id = ?
SQL
   category-id item-id))

(define (insert-barcode! connection barcode item-id)
  (db:query-exec
   connection
   "INSERT INTO catalog_barcodes (barcode, item_id) VALUES (?, ?)"
   barcode item-id))

(module+ test
  (test-case "catalog schema rejects invalid item primitive values"
    (call-with-catalog
     (lambda (connection)
       (check-exn
        db:exn:fail:sql?
        (lambda () (insert-item! connection "" "Apples" 199 1)))
       (check-exn
        db:exn:fail:sql?
        (lambda () (insert-item! connection "item-empty-description" "" 199 1)))
       (check-exn
        db:exn:fail:sql?
        (lambda () (insert-item! connection "item-real-price" "Apples" 199.5 1)))
       (check-exn
        db:exn:fail:sql?
        (lambda () (insert-item! connection "item-negative" "Apples" -1 1)))
       (for ([active (in-list '(-1 2 1.5 "active"))])
         (check-exn
          db:exn:fail:sql?
          (lambda ()
            (insert-item! connection
                          (format "item-active-~a" active)
                          "Apples"
                          199
                          active)))))))

  (test-case "catalog schema rejects empty and duplicate barcodes"
    (call-with-catalog
     (lambda (connection)
       (insert-item! connection "item-apples" "Apples" 199 1)
       (check-exn
        db:exn:fail:sql?
        (lambda () (insert-barcode! connection "" "item-apples")))
       (insert-barcode! connection "049000001234" "item-apples")
       (check-exn
        db:exn:fail:sql?
        (lambda ()
          (insert-barcode! connection "049000001234" "item-apples"))))))

  (test-case "tax schema rejects invalid categories and rates"
    (call-with-catalog
     (lambda (connection)
       (check-exn
        db:exn:fail:sql?
        (lambda () (insert-tax-category! connection "" "Tax" 100000)))
       (check-exn
        db:exn:fail:sql?
        (lambda () (insert-tax-category! connection "empty-description" "" 0)))
       ;; Values that SQLite INTEGER affinity cannot losslessly coerce must
       ;; still violate the stored-type/range constraints.
       (for ([rate (in-list (list -1 1000001 1.5 "not-a-rate"))])
         (check-exn
          db:exn:fail:sql?
          (lambda ()
            (insert-tax-category!
             connection (format "invalid-~a" rate) "Invalid" rate)))))))

  (test-case "known active barcode returns exact immutable catalog facts"
    (call-with-catalog
     (lambda (connection)
       (insert-item! connection "item-apples" "Test Apples" 199 1)
       (insert-tax-category! connection "standard" "Standard" 88750)
       (set-item-tax-category! connection "item-apples" "standard")
       (insert-barcode! connection "049000001234" "item-apples")

       (define item
         (lookup-catalog-item-by-barcode connection "049000001234"))

       (check-pred catalog-item? item)
       (check-equal? (catalog-item-barcode item) "049000001234")
       (check-equal? (catalog-item-description item) "Test Apples")
       (check-equal? (catalog-item-unit-price item) (money 199))
       (check-equal? (catalog-item-tax-category-id item) "standard")
       (check-equal? (catalog-item-tax-rate item) (tax-rate 88750))
       (check-true (immutable? (catalog-item-barcode item)))
       (check-true (immutable? (catalog-item-description item))))))

  (test-case "leading-zero barcode survives lookup unchanged"
    (call-with-catalog
     (lambda (connection)
       (insert-item! connection "item-leading-zero" "Leading Zero" 123 1)
       (insert-barcode! connection "000012340005" "item-leading-zero")

       (define item
         (lookup-catalog-item-by-barcode connection "000012340005"))

       (check-equal? (catalog-item-barcode item) "000012340005"))))

  (test-case "unknown and inactive catalog entries do not resolve"
    (call-with-catalog
     (lambda (connection)
       (insert-item! connection "item-inactive" "Inactive Apples" 199 0)
       (insert-barcode! connection "049000009999" "item-inactive")

       (check-false
        (lookup-catalog-item-by-barcode connection "000000000000"))
       (check-false
        (lookup-catalog-item-by-barcode connection "049000009999")))))

  (test-case "multiple exact barcodes can resolve the same item"
    (call-with-catalog
     (lambda (connection)
       (insert-item! connection "item-apples" "Test Apples" 199 1)
       (insert-barcode! connection "049000001234" "item-apples")
       (insert-barcode! connection "049000001235" "item-apples")

       (define first
         (lookup-catalog-item-by-barcode connection "049000001234"))
       (define second
         (lookup-catalog-item-by-barcode connection "049000001235"))

       (check-equal? (catalog-item-description first) "Test Apples")
       (check-equal? (catalog-item-description second) "Test Apples")
       (check-equal? (catalog-item-barcode first) "049000001234")
       (check-equal? (catalog-item-barcode second) "049000001235"))))

  (test-case "different items remain isolated and zero price is valid"
    (call-with-catalog
     (lambda (connection)
       (insert-item! connection "item-free" "Free Sample" 0 1)
       (insert-item! connection "item-pears" "Pears" 299 1)
       (insert-barcode! connection "000000000001" "item-free")
       (insert-barcode! connection "000000000002" "item-pears")

       (check-equal?
        (catalog-item-unit-price
         (lookup-catalog-item-by-barcode connection "000000000001"))
        (money 0))
       (check-equal?
        (catalog-item-unit-price
         (lookup-catalog-item-by-barcode connection "000000000002"))
        (money 299)))))

  (test-case "orphan barcode is catalog corruption rather than a miss"
    (call-with-catalog
     (lambda (connection)
       ;; Foreign-key enforcement is not yet a runtime connection invariant.
       ;; The read repository must nevertheless distinguish this corrupt row
       ;; from a genuine absent barcode.
       (insert-barcode! connection "049000008888" "missing-item")

       (check-exn
        exn:fail?
        (lambda ()
          (lookup-catalog-item-by-barcode connection "049000008888"))))))

  (test-case "missing item tax mapping is catalog corruption"
    (call-with-catalog
     (lambda (connection)
       (insert-item! connection "item-apples" "Test Apples" 199 1)
       (insert-barcode! connection "049000001234" "item-apples")
       (db:query-exec
        connection
        "DELETE FROM catalog_item_tax_categories WHERE item_id = 'item-apples'")

       (check-exn
        exn:fail?
        (lambda ()
          (lookup-catalog-item-by-barcode connection "049000001234"))))))

  (test-case "missing referenced tax category is catalog corruption"
    (call-with-catalog
     (lambda (connection)
       (insert-item! connection "item-apples" "Test Apples" 199 1)
       (insert-barcode! connection "049000001234" "item-apples")
       (set-item-tax-category! connection "item-apples" "missing-category")

       (check-exn
        exn:fail?
        (lambda ()
          (lookup-catalog-item-by-barcode connection "049000001234")))))))
