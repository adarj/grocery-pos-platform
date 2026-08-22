#lang racket

(require (prefix-in db: db)
         "../domain/catalog-item.rkt"
         "../domain/money.rkt"
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
       item.active
FROM catalog_barcodes AS barcode_assignment
LEFT JOIN catalog_items AS item
  ON item.item_id = barcode_assignment.item_id
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

     (and (= active 1)
          (catalog-item barcode
                        description
                        (money unit-price-minor-units)))]))

(define (verify-activated-catalog! connection snapshot)
  (define expected-item-count
    (length (catalog-snapshot-items snapshot)))
  (define expected-barcode-count
    (length (catalog-snapshot-barcodes snapshot)))
  (define actual-item-count
    (db:query-value connection "SELECT COUNT(*) FROM catalog_items"))
  (define actual-barcode-count
    (db:query-value connection "SELECT COUNT(*) FROM catalog_barcodes"))
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
  (unless (= actual-item-count expected-item-count)
    (error
     'activate-catalog-snapshot!
     "catalog item count changed unexpectedly during activation"))
  (unless (= actual-barcode-count expected-barcode-count)
    (error
     'activate-catalog-snapshot!
     "catalog barcode count changed unexpectedly during activation"))
  (unless (zero? orphan-count)
    (error
     'activate-catalog-snapshot!
     "catalog activation produced orphan barcode assignments")))

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
     (db:query-exec connection "DELETE FROM catalog_items")
     (after-clear)

     ;; The typed snapshot has already proved all barcode references point to
     ;; an item in this same set. Insert all items before their assignments.
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
