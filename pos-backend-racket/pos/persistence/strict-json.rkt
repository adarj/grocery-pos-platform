#lang racket

(require json)

(provide strict-json-string->jsexpr
         strict-json-bytes->jsexpr
         strict-json-success?
         strict-json-success-value
         strict-json-failure?
         strict-json-failure-code
         strict-json-failure-detail)

(struct strict-json-success (value)
  #:transparent)

(struct strict-json-failure (code detail)
  #:transparent)

;; Racket's JSON reader represents objects as hashes, so a repeated member
;; name would otherwise be collapsed before a schema decoder sees it. This
;; scanner runs after syntax validation and compares decoded member names,
;; including names whose source spelling uses JSON escapes.
(define (find-duplicate-json-field raw-bytes)
  (define byte-count (bytes-length raw-bytes))
  (define quote-byte (char->integer #\"))
  (define backslash-byte (char->integer #\\))
  (define left-brace-byte (char->integer #\{))
  (define right-brace-byte (char->integer #\}))
  (define colon-byte (char->integer #\:))

  (define (json-whitespace-byte? byte)
    (member byte '(32 9 10 13)))

  (define (skip-whitespace position)
    (let loop ([position position])
      (if (and (< position byte-count)
               (json-whitespace-byte?
                (bytes-ref raw-bytes position)))
          (loop (add1 position))
          position)))

  (define (scan-string start)
    (unless (and (< start byte-count)
                 (= (bytes-ref raw-bytes start) quote-byte))
      (error 'find-duplicate-json-field "expected a JSON string"))
    (let loop ([position (add1 start)])
      (when (>= position byte-count)
        (error 'find-duplicate-json-field "unterminated JSON string"))
      (define byte (bytes-ref raw-bytes position))
      (cond
        [(= byte quote-byte) (add1 position)]
        [(= byte backslash-byte)
         (when (>= (add1 position) byte-count)
           (error 'find-duplicate-json-field "unterminated JSON escape"))
         (loop (+ position 2))]
        [else (loop (add1 position))])))

  (define (decode-key start end)
    (bytes->jsexpr (subbytes raw-bytes start end)))

  (let loop ([position 0]
             [object-scopes '()])
    (cond
      [(>= position byte-count) #f]
      [else
       (define byte (bytes-ref raw-bytes position))
       (cond
         [(= byte left-brace-byte)
          (loop (add1 position) (cons (hash) object-scopes))]
         [(= byte right-brace-byte)
          (loop (add1 position)
                (if (null? object-scopes)
                    object-scopes
                    (rest object-scopes)))]
         [(= byte quote-byte)
          (define key-end (scan-string position))
          (define after-string (skip-whitespace key-end))
          (cond
            [(and (< after-string byte-count)
                  (= (bytes-ref raw-bytes after-string) colon-byte))
             (unless (pair? object-scopes)
               (error 'find-duplicate-json-field
                      "JSON member name is outside an object"))
             (define key (decode-key position key-end))
             (define current-scope (first object-scopes))
             (if (hash-has-key? current-scope key)
                 key
                 (loop key-end
                       (cons (hash-set current-scope key #t)
                             (rest object-scopes))))]
            [else (loop key-end object-scopes)])]
         [else (loop (add1 position) object-scopes)])])))

(define (read-complete-json input-port)
  (with-handlers ([exn:fail?
                   (lambda (_exception)
                     (strict-json-failure 'malformed-json #f))])
    (define parsed (read-json input-port))
    (let consume-trailing-whitespace ()
      (define next-character (read-char input-port))
      (cond
        [(eof-object? next-character) parsed]
        [(memv next-character '(#\space #\tab #\newline #\return))
         (consume-trailing-whitespace)]
        [else (strict-json-failure 'malformed-json #f)]))))

(define (finish-strict-json-decode parsed raw-bytes)
  (cond
    [(strict-json-failure? parsed) parsed]
    [else
     (define duplicate-or-failure
       (with-handlers ([exn:fail?
                        (lambda (_exception)
                          (strict-json-failure 'malformed-json #f))])
         (find-duplicate-json-field raw-bytes)))
     (cond
       [(strict-json-failure? duplicate-or-failure)
        duplicate-or-failure]
       [duplicate-or-failure
        (strict-json-failure 'duplicate-field duplicate-or-failure)]
       [else (strict-json-success parsed)])]))

(define (strict-json-string->jsexpr text)
  (unless (string? text)
    (raise-argument-error 'strict-json-string->jsexpr "string?" text))
  (finish-strict-json-decode
   (read-complete-json (open-input-string text))
   (string->bytes/utf-8 text)))

(define (strict-json-bytes->jsexpr bytes)
  (unless (bytes? bytes)
    (raise-argument-error 'strict-json-bytes->jsexpr "bytes?" bytes))
  (finish-strict-json-decode
   (read-complete-json (open-input-bytes bytes))
   bytes))
