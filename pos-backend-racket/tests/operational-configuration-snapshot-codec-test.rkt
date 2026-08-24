#lang racket

(require rackunit
         "../pos/persistence/operational-configuration-snapshot-codec.rkt")

(define valid-json
  #<<JSON
{
  "schema_version": 1,
  "register": {
    "register_id": "register-front-01",
    "display_name": "Front Register 1"
  },
  "cashiers": [
    {
      "cashier_id": "cashier-dev-01",
      "display_name": "Development Cashier",
      "active": true
    },
    {
      "cashier_id": "cashier-inactive",
      "display_name": "Inactive Cashier",
      "active": false
    }
  ]
}
JSON
  )

(define (decode text)
  (json-string->operational-configuration-snapshot text))

(define (failure-code text)
  (define result (decode text))
  (check-pred operational-configuration-decode-failure? result)
  (operational-configuration-decode-failure-code result))

(module+ test
  (test-case "valid operational configuration decodes to exact typed values"
    (define result (decode valid-json))
    (check-pred operational-configuration-decode-success? result)
    (define snapshot
      (operational-configuration-decode-success-snapshot result))
    (check-equal? (operational-configuration-snapshot-schema-version snapshot)
                  1)
    (define register
      (operational-configuration-snapshot-register snapshot))
    (check-equal?
     (operational-configuration-register-register-id register)
     "register-front-01")
    (check-equal?
     (operational-configuration-register-display-name register)
     "Front Register 1")
    (define cashiers
      (operational-configuration-snapshot-cashiers snapshot))
    (check-equal? (length cashiers) 2)
    (check-equal?
     (map operational-configuration-cashier-cashier-id cashiers)
     '("cashier-dev-01" "cashier-inactive"))
    (check-equal?
     (map operational-configuration-cashier-active? cashiers)
     '(#t #f)))

  (test-case "strict object and field validation fails closed"
    (check-equal? (failure-code "{") 'malformed-json)
    (check-equal?
     (failure-code
      "{\"schema_version\":1,\"schema_version\":1,\"register\":{},\"cashiers\":[]}")
     'duplicate-field)
    (check-equal?
     (failure-code "{\"schema_version\":1,\"cashiers\":[]}")
     'missing-field)
    (check-equal?
     (failure-code
      "{\"schema_version\":1,\"register\":{\"register_id\":\"r\",\"display_name\":\"R\"},\"cashiers\":[],\"extra\":true}")
     'unexpected-field)
    (check-equal?
     (failure-code
      "{\"schema_version\":2,\"register\":{\"register_id\":\"r\",\"display_name\":\"R\"},\"cashiers\":[]}")
     'unsupported-schema-version))

  (test-case "register and cashier primitive invariants are strict"
    (for ([entry
           (in-list
            (list
             (cons
              "{\"schema_version\":1,\"register\":{\"register_id\":\"\",\"display_name\":\"R\"},\"cashiers\":[]}"
              'invalid-register-id)
             (cons
              "{\"schema_version\":1,\"register\":{\"register_id\":\"r\",\"display_name\":\"\"},\"cashiers\":[]}"
              'invalid-display-name)
             (cons
              "{\"schema_version\":1,\"register\":{\"register_id\":\"r\",\"display_name\":\"R\"},\"cashiers\":[{\"cashier_id\":\"\",\"display_name\":\"C\",\"active\":true}]}"
              'invalid-cashier-id)
             (cons
              "{\"schema_version\":1,\"register\":{\"register_id\":\"r\",\"display_name\":\"R\"},\"cashiers\":[{\"cashier_id\":\"c\",\"display_name\":\"\",\"active\":true}]}"
              'invalid-display-name)
             (cons
              "{\"schema_version\":1,\"register\":{\"register_id\":\"r\",\"display_name\":\"R\"},\"cashiers\":[{\"cashier_id\":\"c\",\"display_name\":\"C\",\"active\":1}]}"
              'invalid-active)))])
      (check-equal? (failure-code (car entry)) (cdr entry))))

  (test-case "duplicate cashier identity rejects the complete snapshot"
    (check-equal?
     (failure-code
      "{\"schema_version\":1,\"register\":{\"register_id\":\"r\",\"display_name\":\"R\"},\"cashiers\":[{\"cashier_id\":\"c\",\"display_name\":\"One\",\"active\":true},{\"cashier_id\":\"c\",\"display_name\":\"Two\",\"active\":false}]}"
     )
     'duplicate-cashier-id)))
