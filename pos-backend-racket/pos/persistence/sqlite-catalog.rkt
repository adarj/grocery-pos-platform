#lang racket

(require (prefix-in db: db)
         "../domain/catalog-item.rkt"
         "../domain/money.rkt")

(provide lookup-catalog-item-by-barcode)

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
