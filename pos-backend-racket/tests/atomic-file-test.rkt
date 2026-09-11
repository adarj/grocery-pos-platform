#lang racket

(require racket/file
         rackunit
         "../pos/persistence/atomic-file.rkt")

(define (call-with-temporary-directory procedure)
  (define directory
    (make-temporary-file "grocery-pos-atomic-file-~a" 'directory))
  (dynamic-wind
    void
    (lambda () (procedure directory))
    (lambda () (delete-directory/files directory))))

(module+ test
  (test-case "atomic publication never overwrites an existing destination"
    (call-with-temporary-directory
     (lambda (directory)
       (define candidate (build-path directory "candidate"))
       (define destination (build-path directory "destination"))
       (display-to-file "candidate" candidate #:exists 'error)
       (display-to-file "caller-owned" destination #:exists 'error)

       (check-exn
        exn:fail?
        (lambda ()
          (atomic-rename-file-no-replace! candidate destination)))
       (check-equal? (file->string candidate) "candidate")
       (check-equal? (file->string destination) "caller-owned"))))

  (test-case "atomic publication and file/directory synchronization succeed"
    (call-with-temporary-directory
     (lambda (directory)
       (define candidate (build-path directory "candidate"))
       (define destination (build-path directory "destination"))
       (display-to-file "durable" candidate #:exists 'error)

       (synchronize-file! candidate)
       (atomic-rename-file-no-replace! candidate destination)
       (synchronize-file! destination)
       (synchronize-directory! directory)

       (check-false (file-exists? candidate))
       (check-equal? (file->string destination) "durable")))))
