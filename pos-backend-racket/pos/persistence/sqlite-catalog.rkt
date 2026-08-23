#lang racket

(require (prefix-in db: db)
         "../domain/catalog-item.rkt"
         "../domain/money.rkt"
         "../domain/tax.rkt"
         "catalog-snapshot-codec.rkt")

(provide lookup-catalog-item-by-barcode
         activate-catalog-snapshot!)

(define (non-empty-string? value)
  (and (string? value)
       (positive? (string-length value))))

(define (catalog-corruption format-string . arguments)
  (apply error
         'lookup-catalog-item-by-barcode
         format-string
         arguments))

(define (lookup-catalog-item-by-barcode connection barcode)
  (unless (db:connection? connection)
    (raise-argument-error
     'lookup-catalog-item-by-barcode "connection?" connection))
  (unless (non-empty-string? barcode)
    (raise-argument-error
     'lookup-catalog-item-by-barcode "non-empty string?" barcode))

  ;; LEFT JOIN deliberately distinguishes a genuinely unknown barcode (no
  ;; assignment row) from an orphan assignment. Foreign-key enforcement is not
  ;; yet a connection-wide runtime invariant, so treating an orphan as a normal
  ;; miss would fail open on corrupt catalog data.
  (define row
    (db:query-maybe-row
     connection
     #<<SQL
SELECT barcode_assignment.item_id,
       item.item_id,
       item.description,
       item.unit_price_minor_units,
       item.active,
       item_tax.item_id,
       item_tax.tax_category_id,
       category.tax_category_id,
       category.rate_millionths
FROM catalog_barcodes AS barcode_assignment
LEFT JOIN catalog_items AS item
  ON item.item_id = barcode_assignment.item_id
LEFT JOIN catalog_item_tax_categories AS item_tax
  ON item_tax.item_id = item.item_id
LEFT JOIN tax_categories AS category
  ON category.tax_category_id = item_tax.tax_category_id
WHERE barcode_assignment.barcode = ?
SQL
     barcode))

  (cond
    [(not row) #f]
    [else
     (define assigned-item-id (vector-ref row 0))
     (define item-id (vector-ref row 1))
     (define description (vector-ref row 2))
     (define unit-price-minor-units (vector-ref row 3))
     (define active (vector-ref row 4))
     (define mapped-item-id (vector-ref row 5))
     (define mapped-tax-category-id (vector-ref row 6))
     (define tax-category-id (vector-ref row 7))
     (define tax-rate-millionths (vector-ref row 8))

     (unless (non-empty-string? assigned-item-id)
       (catalog-corruption
        "catalog barcode has invalid item assignment for barcode ~e"
        barcode))
     (when (db:sql-null? item-id)
       (catalog-corruption
        "catalog barcode references a missing item for barcode ~e"
        barcode))
     (unless (and (non-empty-string? item-id)
                  (string=? assigned-item-id item-id))
       (catalog-corruption
        "catalog barcode item identity is inconsistent for barcode ~e"
        barcode))
     (unless (non-empty-string? description)
       (catalog-corruption
        "catalog item has an invalid description for barcode ~e"
        barcode))
     (unless (and (exact-integer? unit-price-minor-units)
                  (>= unit-price-minor-units 0))
       (catalog-corruption
        "catalog item has an invalid unit price for barcode ~e"
        barcode))
     (unless (and (exact-integer? active)
                  (or (= active 0) (= active 1)))
       (catalog-corruption
        "catalog item has an invalid active value for barcode ~e"
        barcode))
     (when (or (db:sql-null? mapped-item-id)
               (db:sql-null? mapped-tax-category-id))
       (catalog-corruption
        "catalog item lacks a tax category mapping for barcode ~e"
        barcode))
     (unless (and (non-empty-string? mapped-item-id)
                  (string=? item-id mapped-item-id)
                  (non-empty-string? mapped-tax-category-id))
       (catalog-corruption
        "catalog item tax mapping is inconsistent for barcode ~e"
        barcode))
     (when (db:sql-null? tax-category-id)
       (catalog-corruption
        "catalog item references a missing tax category for barcode ~e"
        barcode))
     (unless (and (non-empty-string? tax-category-id)
                  (string=? mapped-tax-category-id tax-category-id))
       (catalog-corruption
        "catalog tax category identity is inconsistent for barcode ~e"
        barcode))
     (unless (and (exact-integer? tax-rate-millionths)
                  (<= 0 tax-rate-millionths 1000000))
       (catalog-corruption
        "catalog item has an invalid tax rate for barcode ~e"
        barcode))

     (and (= active 1)
          (catalog-item barcode
                        description
                        (money unit-price-minor-units)
                        tax-category-id
                        (tax-rate tax-rate-millionths)))]))

(define (verify-activated-catalog! connection snapshot)
  (define expected-item-count
    (length (catalog-snapshot-items snapshot)))
  (define expected-barcode-count
    (length (catalog-snapshot-barcodes snapshot)))
  (define expected-tax-category-count
    (length (catalog-snapshot-tax-categories snapshot)))
  (define actual-item-count
    (db:query-value connection "SELECT COUNT(*) FROM catalog_items"))
  (define actual-barcode-count
    (db:query-value connection "SELECT COUNT(*) FROM catalog_barcodes"))
  (define actual-tax-category-count
    (db:query-value connection "SELECT COUNT(*) FROM tax_categories"))
  (define actual-tax-mapping-count
    (db:query-value
     connection "SELECT COUNT(*) FROM catalog_item_tax_categories"))
  (define orphan-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_barcodes AS barcode_assignment
LEFT JOIN catalog_items AS item
  ON item.item_id = barcode_assignment.item_id
WHERE item.item_id IS NULL
SQL
     ))
  (define orphan-item-tax-mapping-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_item_tax_categories AS mapping
LEFT JOIN catalog_items AS item
  ON item.item_id = mapping.item_id
WHERE item.item_id IS NULL
SQL
     ))
  (define orphan-tax-category-mapping-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_item_tax_categories AS mapping
LEFT JOIN tax_categories AS category
  ON category.tax_category_id = mapping.tax_category_id
WHERE category.tax_category_id IS NULL
SQL
     ))
  (define unmapped-item-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_items AS item
LEFT JOIN catalog_item_tax_categories AS mapping
  ON mapping.item_id = item.item_id
WHERE mapping.item_id IS NULL
SQL
     ))
  (unless (= actual-item-count expected-item-count)
    (error
     'activate-catalog-snapshot!
     "catalog item count changed unexpectedly during activation"))
  (unless (= actual-barcode-count expected-barcode-count)
    (error
     'activate-catalog-snapshot!
     "catalog barcode count changed unexpectedly during activation"))
  (unless (= actual-tax-category-count expected-tax-category-count)
    (error
     'activate-catalog-snapshot!
     "catalog tax category count changed unexpectedly during activation"))
  (unless (= actual-tax-mapping-count expected-item-count)
    (error
     'activate-catalog-snapshot!
     "catalog item tax mapping count changed unexpectedly during activation"))
  (unless (zero? orphan-count)
    (error
     'activate-catalog-snapshot!
     "catalog activation produced orphan barcode assignments"))
  (unless (zero? orphan-item-tax-mapping-count)
    (error
     'activate-catalog-snapshot!
     "catalog activation produced tax mappings for missing items"))
  (unless (zero? orphan-tax-category-mapping-count)
    (error
     'activate-catalog-snapshot!
     "catalog activation produced tax mappings for missing categories"))
  (unless (zero? unmapped-item-count)
    (error
     'activate-catalog-snapshot!
     "catalog activation produced items without tax mappings")))

(define (activate-catalog-snapshot/observe!
         connection snapshot after-clear)
  (unless (db:connection? connection)
    (raise-argument-error
     'activate-catalog-snapshot! "connection?" connection))
  (unless (catalog-snapshot? snapshot)
    (raise-argument-error
     'activate-catalog-snapshot! "catalog-snapshot?" snapshot))
  (unless (and (procedure? after-clear)
               (procedure-arity-includes? after-clear 0))
    (raise-argument-error
     'activate-catalog-snapshot! "zero-argument procedure?" after-clear))

  (db:call-with-transaction
   connection
   (lambda ()
     ;; Delete assignments first because they logically depend on items. All
     ;; replacement rows remain invisible to other connections until commit.
     (db:query-exec connection "DELETE FROM catalog_barcodes")
     (db:query-exec connection "DELETE FROM catalog_item_tax_categories")
     (db:query-exec connection "DELETE FROM catalog_items")
     (db:query-exec connection "DELETE FROM tax_categories")
     (after-clear)

     ;; The typed snapshot has already proved all references remain within the
     ;; same complete set. Insert dependencies before their assignments.
     (for ([category
            (in-list (catalog-snapshot-tax-categories snapshot))])
       (db:query-exec
        connection
        #<<SQL
INSERT INTO tax_categories
  (tax_category_id, description, rate_millionths)
VALUES (?, ?, ?)
SQL
        (catalog-snapshot-tax-category-tax-category-id category)
        (catalog-snapshot-tax-category-description category)
        (catalog-snapshot-tax-category-rate-millionths category)))
     (for ([item (in-list (catalog-snapshot-items snapshot))])
       (db:query-exec
        connection
        #<<SQL
INSERT INTO catalog_items
  (item_id, description, unit_price_minor_units, active)
VALUES (?, ?, ?, ?)
SQL
        (catalog-snapshot-item-item-id item)
        (catalog-snapshot-item-description item)
        (catalog-snapshot-item-unit-price-minor-units item)
        (if (catalog-snapshot-item-active? item) 1 0)))
     (for ([item (in-list (catalog-snapshot-items snapshot))])
       (db:query-exec
        connection
        #<<SQL
INSERT INTO catalog_item_tax_categories (item_id, tax_category_id)
VALUES (?, ?)
SQL
        (catalog-snapshot-item-item-id item)
        (catalog-snapshot-item-tax-category-id item)))
     (for ([assignment (in-list (catalog-snapshot-barcodes snapshot))])
       (db:query-exec
        connection
        #<<SQL
INSERT INTO catalog_barcodes (barcode, item_id)
VALUES (?, ?)
SQL
        (catalog-snapshot-barcode-barcode assignment)
        (catalog-snapshot-barcode-item-id assignment)))
     (verify-activated-catalog! connection snapshot))
   #:option 'immediate)

  (summarize-catalog-snapshot snapshot))

(define (activate-catalog-snapshot! connection snapshot)
  (activate-catalog-snapshot/observe! connection snapshot void))

(module+ test-support
  (provide activate-catalog-snapshot/observe!))
