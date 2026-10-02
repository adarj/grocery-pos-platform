#lang racket/base

(require rackunit
         racket/unix-socket
         racket/file
         racket/port
         json
         "../pos/edge/client.rkt"
         "../pos/edge/protocol.rkt")

(provide with-peer fixed)

;; Hostile-response qualification fixture only; production HTTP parsing is the
;; pinned mature client. This peer deliberately supplies fixed response bytes.
(define (with-peer response work #:hold [hold 0] #:template [template "edge-hostile-~a"])
  (define directory (make-temporary-file template 'directory))
  (define path (build-path directory "edge.sock"))
  (define cust (make-custodian))
  (define listener (parameterize ([current-custodian cust]) (unix-socket-listen path)))
  (define served (make-semaphore 0))
  (parameterize ([current-custodian cust])
    (thread
     (lambda ()
       (define-values (in out) (unix-socket-accept listener))
       (with-handlers ([exn:fail? void])
         (read-byte in)
         (write-bytes response out)
         (flush-output out)
         (sleep hold))
       (close-input-port in)
       (close-output-port out)
       (semaphore-post served))))
  (dynamic-wind
   void
   (lambda () (work (make-edge-client path #:timeout 2) listener served))
   (lambda ()
     (unix-socket-close-listener listener)
     (custodian-shutdown-all cust)
     (delete-directory/files directory))))

(define (fixed status body [extra #""])
  (bytes-append
   status
   #"\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
   (string->bytes/utf-8 (number->string (bytes-length body)))
   #"\r\n"
   extra
   #"\r\n"
   body))

(module+ test
  (test-case "UDS authority preserves case-sensitive filesystem path bytes"
    (with-peer
     (fixed
      #"HTTP/1.1 200 OK"
      (jsexpr->bytes (hasheq 'agent_instance_id "a" 'protocol_version (hasheq 'major 1 'minor 0))))
     (lambda (client _listener _served) (check-true (edge-response? (edge-health client))))
     #:template "edge-Case-~a"))

  (test-case "redirect is a protocol failure and never creates a second transmission"
    (with-peer
     (fixed #"HTTP/1.1 307 Temporary Redirect" #"{}" #"Location: /v1/health\r\n")
     (lambda (client listener served)
       (check-equal? (edge-malformed-response-code (edge-health client)) 'unexpected-status)
       (check-not-false (sync/timeout 1 served))
       (check-false (sync/timeout .05 (unix-socket-accept-evt listener))))))

  (test-case "malformed JSON and unknown safety enum are typed untrusted response failures"
    (with-peer
     (fixed #"HTTP/1.1 200 OK" #"{} {}")
     (lambda (client _listener _served)
       (check-true (edge-malformed-response? (edge-health client)))))
    (with-peer
     (fixed
      #"HTTP/1.1 200 OK"
      (jsexpr->bytes
       (hasheq
        'agent_instance_id "a"
        'device_id "d"
        'binding_instance_id 'null
        'state_revision 0
        'adapter_kind "synthetic"
        'availability "unrecognized"
        'conditions null
        'capabilities null)))
     (lambda (client _listener _served)
       (check-equal? (edge-malformed-response-code (edge-device client "d")) 'unknown-safety-enum))))

  (test-case "a rejection for another request cannot be treated as this POST's rejection"
    (with-peer
     (fixed
      #"HTTP/1.1 409 Conflict"
      (jsexpr->bytes
       (hasheq 'request_id "another-request" 'error (hasheq 'code "edge.semantic_conflict"))))
     (lambda (client _listener _served)
       (define a
         (make-edge-command-attempt
          #:agent-id "a"
          #:device-id "d"
          #:binding-id "b"
          #:not-after 100
          #:timeout 10
          #:payload (make-edge-payload "synthetic.signal" (hasheq 'token 1))))
       (check-true (edge-malformed-response? (edge-submit-command client a))))))

  (test-case "huge advertised HTTP chunk does not allocate its declared length"
    (with-peer
     (bytes-append
      #"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nffffffffffffffff\r\n"
      (make-bytes (add1 non-stream-max-bytes) 120))
     (lambda (client _listener _served)
       (check-equal? (edge-malformed-response-code (edge-health client)) 'response-too-large))
     #:hold .2))

  (test-case "truncated HTTP body cannot turn a complete JSON prefix into success"
    (define body
      (jsexpr->bytes (hasheq 'agent_instance_id "a" 'protocol_version (hasheq 'major 1 'minor 0))))
    (with-peer
     (bytes-append
      #"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
      (string->bytes/utf-8 (number->string (add1 (bytes-length body))))
      #"\r\n\r\n"
      body)
     (lambda (client _listener _served) (check-false (edge-response? (edge-health client))))))

  (test-case "incomplete or ambiguous response framing never publishes valid JSON as success"
    (define body
      (jsexpr->bytes (hasheq 'agent_instance_id "a" 'protocol_version (hasheq 'major 1 'minor 0))))
    (define prefix #"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n")
    (define chunk
      (bytes-append
       (string->bytes/utf-8 (number->string (bytes-length body) 16))
       #"\r\n"
       body
       #"\r\n"))
    (for ([response
           (in-list
            (list
             (bytes-append prefix #"Transfer-Encoding: chunked\r\n\r\n" chunk #"0\r\n")
             (bytes-append prefix #"Content-Length: +inf.0\r\n\r\n" body)
             (bytes-append
              prefix
              #"Content-Length: "
              (string->bytes/utf-8 (number->string (bytes-length body)))
              #"\r\nContent-Length: 999\r\n\r\n"
              body)
             (bytes-append
              prefix
              #"Content-Length: 999\r\nTransfer-Encoding: chunked\r\n\r\n"
              chunk
              #"0\r\n\r\n")
             (bytes-append
              prefix
              #"Transfer-Encoding: chunked\r\n\r\n+"
              (string->bytes/utf-8 (number->string (bytes-length body) 16))
              #"\r\n"
              body
              #"\r\n0\r\n\r\n")))])
      (with-peer
       response
       (lambda (client _listener _served) (check-false (edge-response? (edge-health client)))))))

  (test-case "unsupported response compression is rejected without a decoder thread error"
    (define diagnostics (open-output-bytes))
    (parameterize ([current-error-port diagnostics])
      (for ([header (in-list '(#"Content-Encoding: gzip\r\n" #"Content-Encoding:gzip\r\n"))])
        (with-peer
         (fixed
          #"HTTP/1.1 200 OK"
          (jsexpr->bytes
           (hasheq 'agent_instance_id "a" 'protocol_version (hasheq 'major 1 'minor 0)))
          header)
         (lambda (client _listener _served)
           (check-equal? (edge-malformed-response-code (edge-health client)) 'content-encoding)
           (sleep .05)))))
    (check-equal? (get-output-bytes diagnostics) #""))

  (test-case "coalesced NDJSON records are separated by newline rather than HTTP chunks"
    (define records
      (bytes-append
       (jsexpr->bytes
        (hasheq
         'type "snapshot"
         'agent_instance_id "a"
         'event_cursor 41
         'agent_uptime_ms 100
         'devices null))
       #"\n"
       (jsexpr->bytes (hasheq 'type "heartbeat" 'agent_instance_id "a" 'agent_uptime_ms 110))
       #"\n"))
    (define response
      (bytes-append
       #"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
       (string->bytes/utf-8 (number->string (bytes-length records) 16))
       #"\r\n"
       records
       #"\r\n0\r\n\r\n"))
    (with-peer
     response
     (lambda (client _listener _served)
       (define stream (edge-open-events client))
       (dynamic-wind
        void
        (lambda ()
          (check-true
           (edge-snapshot-event?
            (parse-edge-event (decode-edge-json (read-edge-record (edge-stream-input stream))))))
          (check-true
           (edge-heartbeat?
            (parse-edge-event (decode-edge-json (read-edge-record (edge-stream-input stream)))))))
        (lambda () (close-edge-stream! stream)))))))
