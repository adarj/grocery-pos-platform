#lang racket

(require racket/file
         rackunit
         "../pos/persistence/sqlite-restore.rkt"
         "../pos/support/appliance-recovery.rkt")

(define (fake-prepared operation-id)
  (prepared-sqlite-restore
   operation-id 1 "/selected.db" "/var/lib/grocery-pos/pos.db"
   "/var/lib/grocery-pos/.restore.partial" 'selected 'staged))

(define (fake-installed prepared recovery-directory)
  (sqlite-restore-installed prepared recovery-directory '() 6))

(module+ test
  (test-case "recovery reads only validated listener keys without executing config"
    (define directory
      (make-temporary-file "grocery-pos-recovery-config-~a" 'directory))
    (dynamic-wind
      void
      (lambda ()
        (define config-path (build-path directory "pos-core.env"))
        (display-to-file
         "GROCERY_POS_ENV=production\nRACKET_API_HOST=::1\nRACKET_API_PORT=7440\n"
         config-path
         #:exists 'error)
        (define-values (host port)
          (read-pos-core-listener-config config-path))
        (check-equal? host "::1")
        (check-equal? port 7440)

        (define sentinel-path (build-path directory "must-not-exist"))
        (display-to-file
         (format "RACKET_API_HOST=127.0.0.1\nRACKET_API_PORT=$(touch ~a)\n"
                 sentinel-path)
         config-path
         #:exists 'replace)
        (check-exn exn:fail?
                   (lambda ()
                     (read-pos-core-listener-config config-path)))
        (check-false (file-exists? sentinel-path))

        (display-to-file
         "RACKET_API_HOST=0.0.0.0\nRACKET_API_PORT=7340\n"
         config-path
         #:exists 'replace)
        (check-exn exn:fail?
                   (lambda ()
                     (read-pos-core-listener-config config-path))))
      (lambda () (delete-directory/files directory))))

  (test-case "appliance restore rejects non-root before preparing state"
    (define calls '())
    (check-exn
     (lambda (exception)
       (and (exn:fail:appliance-recovery? exception)
            (eq? (exn:fail:appliance-recovery-code exception)
                 'not_privileged)))
     (lambda ()
       (restore-pos-appliance!
        "/selected.db"
        #:effective-user-id (lambda () 1000)
        #:prepare (lambda _arguments (set! calls '(prepare))))))
    (check-equal? calls '()))

  (test-case "service-aware restore orders offline replacement and readiness"
    (define calls '())
    (define prepared (fake-prepared "restore-ordered"))
    (define installed
      (fake-installed prepared "/var/lib/grocery-pos/recovery/restore-ordered"))
    (define active-results (list #f #t #t))
    (define ready-results (list #f #t))
    (define (record! name) (set! calls (append calls (list name))))
    (define result
      (restore-pos-appliance!
       "/selected.db"
       #:effective-user-id (lambda () 0)
       #:prepare
       (lambda (backup target)
         (record! (list 'prepare backup target))
         prepared)
       #:abandon (lambda (_prepared) (record! 'abandon))
       #:stop-service! (lambda () (record! 'stop) #t)
       #:service-active?
       (lambda ()
         (record! 'active?)
         (begin0 (car active-results)
           (set! active-results (cdr active-results))))
       #:install
       (lambda (_prepared)
         (record! 'install)
         installed)
       #:finalize-installed!
       (lambda (_installed) (record! 'finalize) #t)
       #:start-service! (lambda () (record! 'start) #t)
       #:readiness-ready?
       (lambda ()
         (record! 'ready?)
         (begin0 (car ready-results)
           (set! ready-results (cdr ready-results))))
       #:sleep (lambda (_seconds) (record! 'sleep))
       #:now-seconds (let ([now 0]) (lambda () (begin0 now (set! now (+ now 0.1)))))))

    (check-true (appliance-restore-success? result))
    (check-equal? (appliance-restore-success-operation-id result)
                  "restore-ordered")
    (check-equal?
     calls
     (list (list 'prepare "/selected.db" canonical-pos-database-path)
           'stop 'active? 'install 'finalize 'start
           'active? 'ready? 'sleep 'active? 'ready?)))

  (test-case "readiness failure stops service without automatic rollback"
    (define directory
      (make-temporary-file "grocery-pos-recovery-orchestration-~a" 'directory))
    (define recovery-directory
      (build-path directory "recovery" "restore-not-ready"))
    (make-directory* recovery-directory)
    (define prepared (fake-prepared "restore-not-ready"))
    (define installed (fake-installed prepared recovery-directory))
    (define calls '())
    (define active-results (list #f #t #t #t))
    (define clock 0)
    (dynamic-wind
      void
      (lambda ()
        (check-exn
         (lambda (exception)
           (and (exn:fail:appliance-recovery? exception)
                (eq? (exn:fail:appliance-recovery-code exception)
                     'readiness_failed)
                (equal?
                 (exn:fail:appliance-recovery-operation-id exception)
                 "restore-not-ready")
                (equal?
                 (exn:fail:appliance-recovery-recovery-directory exception)
                 recovery-directory)))
         (lambda ()
           (restore-pos-appliance!
            "/selected.db"
            #:effective-user-id (lambda () 0)
            #:prepare (lambda (_backup _target) prepared)
            #:abandon (lambda (_prepared) (set! calls (cons 'abandon calls)))
            #:stop-service!
            (lambda () (set! calls (cons 'stop calls)) #t)
            #:service-active?
            (lambda ()
              (begin0 (car active-results)
                (set! active-results (cdr active-results))))
            #:install (lambda (_prepared) installed)
            #:finalize-installed! (lambda (_installed) #t)
            #:start-service! (lambda () #t)
            #:readiness-ready? (lambda () #f)
            #:readiness-timeout-seconds 0.2
            #:sleep (lambda (_seconds) (set! clock (+ clock 0.1)))
            #:now-seconds (lambda () clock))))
        ;; The final stop is explicit, and no abandon/rollback occurs after
        ;; displacement and installation.
        (check-equal? (reverse calls) '(stop stop))
        (check-true (directory-exists? recovery-directory)))
      (lambda () (delete-directory/files directory))))

  (test-case "stop failure abandons staging before displacement"
    (define abandoned? #f)
    (define prepared (fake-prepared "restore-stop-failed"))
    (check-exn
     (lambda (exception)
       (and (exn:fail:appliance-recovery? exception)
            (eq? (exn:fail:appliance-recovery-code exception)
                 'service_stop_failed)))
     (lambda ()
       (restore-pos-appliance!
        "/selected.db"
        #:effective-user-id (lambda () 0)
        #:prepare (lambda (_backup _target) prepared)
        #:abandon (lambda (_prepared) (set! abandoned? #t))
        #:stop-service! (lambda () #f))))
    (check-true abandoned?)))
