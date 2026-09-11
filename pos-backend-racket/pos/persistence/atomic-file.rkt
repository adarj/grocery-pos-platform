#lang racket

(require ffi/unsafe)

(provide atomic-rename-file-no-replace!
         synchronize-file!
         synchronize-directory!)

(define renameat2
  (get-ffi-obj
   "renameat2"
   #f
   (_fun #:save-errno 'posix
         _int
         _bytes/nul-terminated
         _int
         _bytes/nul-terminated
         _uint
         ->
         _int)
   (lambda () #f)))

(define libc-open
  (get-ffi-obj
   "open"
   #f
   (_fun #:save-errno 'posix _bytes/nul-terminated _int -> _int)))

(define libc-fsync
  (get-ffi-obj
   "fsync"
   #f
   (_fun #:save-errno 'posix _int -> _int)))

(define libc-close
  (get-ffi-obj
   "close"
   #f
   (_fun #:save-errno 'posix _int -> _int)))

(define at-fdcwd -100)
(define rename-noreplace #x1)
(define open-read-only 0)

(define (checked-path who label value)
  (unless (path-string? value)
    (raise-argument-error who "path-string?" value))
  (define result (if (path? value) value (string->path value)))
  (when (zero? (bytes-length (path->bytes result)))
    (raise-arguments-error who "path must not be empty" label value))
  result)

(define (atomic-rename-file-no-replace!
         source-path
         destination-path
         #:who [who 'atomic-rename-file-no-replace!])
  (define source (checked-path who "source-path" source-path))
  (define destination
    (checked-path who "destination-path" destination-path))
  (unless renameat2
    (error who
           "atomic non-overwriting file rename is unsupported on this platform"))
  (define result
    (renameat2 at-fdcwd
               (path->bytes source)
               at-fdcwd
               (path->bytes destination)
               rename-noreplace))
  (unless (zero? result)
    (error who
           "atomic non-overwriting file rename failed (errno ~a)"
           (saved-errno))))

(define (synchronize-path! who path label)
  (define checked (checked-path who label path))
  (define descriptor (libc-open (path->bytes checked) open-read-only))
  (when (= descriptor -1)
    (error who "could not open path for synchronization (errno ~a)"
           (saved-errno)))
  (dynamic-wind
    void
    (lambda ()
      (unless (zero? (libc-fsync descriptor))
        (error who "filesystem synchronization failed (errno ~a)"
               (saved-errno))))
    (lambda ()
      (unless (zero? (libc-close descriptor))
        (error who "could not close synchronized path (errno ~a)"
               (saved-errno))))))

(define (synchronize-file! path #:who [who 'synchronize-file!])
  (synchronize-path! who path "file-path"))

(define (synchronize-directory! path #:who [who 'synchronize-directory!])
  (synchronize-path! who path "directory-path"))
