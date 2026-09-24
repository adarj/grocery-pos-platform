#lang racket

(require (prefix-in db: db))

(provide seed-authenticated-test-operator!)

;; Historical business tests construct an internal principal directly. CP6's
;; final writer check requires matching authoritative security state as well.
(define (seed-authenticated-test-operator! connection operator-id role)
  (db:query-exec
   connection "INSERT OR IGNORE INTO operators VALUES (?, ?, 1)"
   operator-id operator-id)
  (db:query-exec
   connection "INSERT OR IGNORE INTO operator_roles VALUES (?, ?)"
   operator-id (symbol->string role))
  (db:query-exec
   connection
   "INSERT OR IGNORE INTO operator_pin_credentials VALUES (?, '$argon2id$fixture', 1)"
   operator-id))
