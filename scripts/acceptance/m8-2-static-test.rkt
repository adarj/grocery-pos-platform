#lang racket

(require json rackunit racket/file racket/runtime-path racket/system)

(define-runtime-path root "../..")

(module+ test
  (define scratch (make-temporary-file "m8-2-static-test-~a" 'directory))

  (define clone (build-path scratch "source"))

  (define metadata (build-path scratch "metadata.json"))

  (define sink (open-output-nowhere))

  (define (run . args)
    (parameterize ([current-output-port sink] [current-error-port sink])
      (apply system*/exit-code args)))

  (define (check-static)
    (parameterize ([current-directory clone])
      (run (find-executable-path "racket") "scripts/acceptance/check-m8-2-static.rkt" metadata)))

  (dynamic-wind
   void
   (lambda ()
     (check-equal?
      (run
       (find-executable-path "racket")
       (build-path root "scripts/acceptance/nix-source-snapshot.rkt")
       root
       clone)
      0)
     (call-with-output-file
      metadata
      (lambda (out)
        (parameterize ([current-output-port out] [current-error-port sink])
          (check-equal?
           (system*/exit-code
            (find-executable-path "cargo")
            "metadata"
            "--locked"
            "--no-deps"
            "--format-version"
            "1"
            "--manifest-path"
            (build-path clone "rust/edge/Cargo.toml"))
           0))))
     (define baseline (call-with-input-file metadata read-json))
     (test-case "unchanged classified source passes static audit" (check-equal? (check-static) 0))
     (for ([entry
            (list
             (list
              "TCP after an inline test module is still production source"
              "rust/edge/crates/edge-server/src/http.rs"
              "\nfn bypass() { let _ = std::net::TcpListener::bind(\"127.0.0.1:0\"); }\n")
             (list
              "new admin route after test module is classified"
              "rust/edge/crates/edge-server/src/http.rs"
              "\nconst BYPASS: &str = \"/v1/admin\";\n")
             (list
              "Flutter cannot introduce a direct command route"
              "flutter/apps/pos_terminal/lib/main.dart"
              "\nconst edgeBypass = '/v1/commands';\n")
             (list
              "Rust cannot introduce SQLite access"
              "rust/edge/crates/edge-core/src/actor.rs"
              "\nconst DB: &str = \"pos.db\";\n")
             (list
              "migration 13 is not generic-edge qualification scope"
              "pos-backend-racket/pos/persistence/pos-database-migrations.rkt"
              "\n(pos-database-migration 13\n 'unexpected)\n")
             (list
              "ordinary Racket startup cannot import Edge implicitly"
              "pos-backend-racket/pos/runtime.rkt"
              "\n(require \"edge/client.rkt\")\n"))])
       (test-case (first entry)
         (define file (build-path clone (second entry)))
         (define original (file->bytes file))
         (dynamic-wind
          (lambda ()
            (call-with-output-file
             file
             (lambda (out)
               (write-bytes original out)
               (display (third entry) out))
             #:exists 'truncate))
          (lambda () (check-not-equal? (check-static) 0))
          (lambda ()
            (call-with-output-file
             file
             (lambda (out) (write-bytes original out))
             #:exists 'truncate)))))
     (for ([entry '("edge-core" "edge-server")])
       (test-case (format "~a dependency authority cannot change silently" entry)
         (define changed
           (hash-set
            baseline
            'packages
            (for/list ([p (hash-ref baseline 'packages)])
              (if (equal? (hash-ref p 'name) entry)
                  (hash-set
                   p
                   'dependencies
                   (if (equal? entry "edge-core")
                       (cons (hasheq 'name "tokio" 'kind 'null) (hash-ref p 'dependencies))
                       (for/list ([d (hash-ref p 'dependencies)])
                         (if (equal? (hash-ref d 'name) "edge-sim") (hash-set d 'optional #f) d))))
                  p))))
         (dynamic-wind
          (lambda ()
            (call-with-output-file
             metadata
             (lambda (out) (write-json changed out))
             #:exists 'truncate))
          (lambda () (check-not-equal? (check-static) 0))
          (lambda ()
            (call-with-output-file
             metadata
             (lambda (out) (write-json baseline out))
             #:exists 'truncate)))))
     (check-equal? (check-static) 0))
   (lambda ()
     (close-output-port sink)
     (delete-directory/files scratch))))
