#lang racket/base

(require (prefix-in http: net/http-easy)
         net/uri-codec
         json
         file/sha1
         racket/random
         racket/port
         racket/string
         "protocol.rkt")

(provide make-edge-client
         edge-client?
         edge-health
         edge-status
         edge-devices
         edge-device
         edge-command-status
         edge-submit-command
         edge-open-events
         make-edge-payload
         edge-payload?
         make-edge-command-attempt
         edge-command-attempt?
         edge-command-attempt-command-id
         edge-command-attempt-agent-id
         edge-command-attempt-device-id
         edge-command-attempt-binding-id
         edge-command-attempt-deadline
         edge-command-attempt-timeout
         edge-command-attempt-kind
         (struct-out edge-response)
         (struct-out edge-rejection)
         (struct-out edge-transport-failure)
         (struct-out edge-malformed-response)
         edge-stream?
         edge-stream-input
         close-edge-stream!)

;; Deliberately opaque: payload bytes never enter ordinary printed diagnostics.
(struct edge-payload (kind bytes))

(struct edge-command-attempt
  (command-id agent-id device-id binding-id deadline timeout kind payload))

(struct edge-client (url timeout))

(struct edge-response (status value received-monotonic-ms) #:transparent)

(struct edge-rejection (status error) #:transparent)

(struct edge-transport-failure (phase uncertain? request-id command-id) #:transparent)

(struct edge-malformed-response (code) #:transparent)

(struct edge-stream (input close))

(define (close-edge-stream! stream)
  ((edge-stream-close stream)))

(define (fresh-id)
  (string->immutable-string (bytes->hex-string (crypto-random-bytes 32))))

(define (socket-authority path)
  ;; HTTP URL normalization lowercases host text. Encode every UTF-8 byte so
  ;; case-sensitive filesystem path bytes survive that normalization exactly.
  (apply
   string-append
   (for/list ([byte (in-bytes (string->bytes/utf-8 path))])
     (string-append "%" (if (< byte 16) "0" "") (number->string byte 16)))))

(define (make-edge-client socket-path #:timeout [timeout 5])
  (unless (and (path-string? socket-path) (complete-path? socket-path))
    (raise-argument-error 'make-edge-client "absolute filesystem socket pathname" socket-path))
  (unless (and (rational? timeout) (positive? timeout))
    (raise-argument-error 'make-edge-client "finite positive timeout" timeout))
  (edge-client
   (string-append
    "http+unix://"
    (socket-authority
     (path->string (if (path? socket-path) socket-path (string->path socket-path)))))
   timeout))

(define (make-edge-payload kind value)
  (unless (edge-id? kind)
    (raise-argument-error 'make-edge-payload "bounded semantic kind" kind))
  (unless (jsexpr? value)
    (raise-argument-error 'make-edge-payload "JSON-representable compiled payload" "<redacted>"))
  (define bytes (jsexpr->bytes value))
  (unless (<= (bytes-length bytes) non-stream-max-bytes)
    (raise-arguments-error 'make-edge-payload "payload exceeds bound"))
  (edge-payload (string->immutable-string kind) (bytes->immutable-bytes bytes)))

(define (make-edge-command-attempt
         #:agent-id agent
         #:device-id device
         #:binding-id binding
         #:not-after deadline
         #:timeout timeout
         #:payload payload)
  (unless (and
           (andmap edge-id? (list agent device binding))
           (edge-u64? deadline)
           (edge-u64? timeout)
           (positive? timeout)
           (edge-payload? payload))
    (raise-arguments-error 'make-edge-command-attempt "invalid typed attempt fields"))
  (edge-command-attempt
   (fresh-id)
   (string->immutable-string agent)
   (string->immutable-string device)
   (string->immutable-string binding)
   deadline
   timeout
   (edge-payload-kind payload)
   payload))

(define (attempt-bytes attempt request-id)
  (jsexpr->bytes
   (hasheq
    'request_id request-id
    'command_id (edge-command-attempt-command-id attempt)
    'expected_agent_instance_id (edge-command-attempt-agent-id attempt)
    'device_id (edge-command-attempt-device-id attempt)
    'expected_binding_instance_id (edge-command-attempt-binding-id attempt)
    'not_after_agent_uptime_ms (edge-command-attempt-deadline attempt)
    'timeout_ms (edge-command-attempt-timeout attempt)
    'kind (edge-command-attempt-kind attempt)
    'payload (bytes->jsexpr (edge-payload-bytes (edge-command-attempt-payload attempt))))))

(define (request
         client
         path
         parse
         #:method [method 'get]
         #:attempt [attempt #f]
         #:events? [events? #f])
  (define request-id (fresh-id))
  (define cust (make-custodian))
  (define session #f)
  (define input #f)
  (define response #f)
  (define closed? #f)

  (define (cleanup)
    (unless closed?
      (set! closed? #t)
      (when (and input (not (port-closed? input)))
        (close-input-port input))
      ;; Closing the dedicated per-request session abandons its connection.
      ;; No response draining, pool reuse, or hidden retry survives cleanup.
      (when response
        (http:response-close! response))
      (when session
        (http:session-close! session))
      (custodian-shutdown-all cust)))

  (with-handlers ([exn:fail:edge-protocol?
                   (lambda (e)
                     (cleanup)
                     (edge-malformed-response (exn:fail:edge-protocol-code e)))]
                  [exn:fail?
                   (lambda (_)
                     (cleanup)
                     (edge-transport-failure
                      'response
                      (and attempt #t)
                      request-id
                      (and attempt (edge-command-attempt-command-id attempt))))])
    (set!
     response
     (parameterize ([current-custodian cust])
       (set! session (http:make-session #:proxies null))
       ;; close? #t would force http-easy to collect the entire response even
       ;; with stream? #t. Send Connection: close and read the bounded port.
       (http:session-request
        session
        (string-append (edge-client-url client) path)
        #:method method
        #:stream? #t
        #:close? #f
        #:headers (if attempt
                      (hasheq
                       'connection #"close"
                       'accept-encoding #"identity"
                       'content-type #"application/json")
                      (hasheq 'connection #"close" 'accept-encoding #"identity"))
        #:data (and attempt (attempt-bytes attempt request-id))
        #:max-attempts 1
        #:max-redirects 0
        #:timeouts (http:make-timeout-config
                    #:lease (edge-client-timeout client)
                    #:connect (edge-client-timeout client)
                    #:request (edge-client-timeout client)))))
    (set! input (http:response-output response))
    (define status (http:response-status-code response))
    (when (http:response-headers-ref response 'content-encoding)
      (raise
       (exn:fail:edge-protocol
        "Unsupported Edge encoding"
        (current-continuation-marks)
        'content-encoding)))
    (define media (or (http:response-headers-ref response 'content-type) #""))
    (define expected-media
      (if (and events? (= status 200)) "application/x-ndjson" "application/json"))
    (unless (string-ci=?
             (string-trim (car (string-split (bytes->string/utf-8 media #f) ";")))
             expected-media)
      (raise
       (exn:fail:edge-protocol "Invalid Edge media type" (current-continuation-marks) 'media-type)))
    (cond
      [(and events? (= status 200)) (edge-stream input cleanup)]
      [else
       (define result-channel (make-channel))
       (parameterize ([current-custodian cust])
         (thread
          (lambda ()
            (with-handlers ([exn:fail? (lambda (e) (channel-put result-channel e))])
              (channel-put result-channel (read-edge-body input))))))
       (define bytes (sync/timeout (edge-client-timeout client) result-channel))
       (unless bytes
         (error 'edge-request "response timeout"))
       (when (exn? bytes)
         (raise bytes))
       (define obj (decode-edge-json bytes))
       (define result
         (cond
           [(member status (if attempt '(200 202) '(200)))
            (define value (parse obj))
            (when attempt
              (define state (edge-command-response-command value))
              (unless (and
                       (equal? request-id (edge-command-response-request-id value))
                       (equal?
                        (edge-command-attempt-command-id attempt)
                        (edge-command-state-command-id state))
                       (equal?
                        (edge-command-attempt-agent-id attempt)
                        (edge-command-state-agent-id state))
                       (equal?
                        (edge-command-attempt-device-id attempt)
                        (edge-command-state-device-id state))
                       (equal?
                        (edge-command-attempt-binding-id attempt)
                        (edge-command-state-binding-id state))
                       (equal? (edge-command-attempt-kind attempt) (edge-command-state-kind state)))
                (raise
                 (exn:fail:edge-protocol
                  "Invalid Edge command correlation"
                  (current-continuation-marks)
                  'correlation))))
            (edge-response
             status
             value
             (inexact->exact (floor (current-inexact-monotonic-milliseconds))))]
           [(member status '(400 404 405 408 409 413 415 422 503))
            (define error (parse-edge-error obj))
            (when (and
                   attempt
                   (edge-protocol-error-request-id error)
                   (not (equal? request-id (edge-protocol-error-request-id error))))
              (raise
               (exn:fail:edge-protocol
                "Invalid Edge request correlation"
                (current-continuation-marks)
                'correlation)))
            (edge-rejection status error)]
           [else (edge-malformed-response 'unexpected-status)]))
       (cleanup)
       result])))

(define (edge-health client)
  (request client "/v1/health" parse-edge-health))

(define (edge-status client)
  (request client "/v1/status" parse-edge-status))

(define (edge-devices client)
  (request client "/v1/devices" parse-edge-devices))

(define (edge-device client id)
  (unless (edge-id? id)
    (raise-argument-error 'edge-device "bounded device ID" id))
  (request client (string-append "/v1/devices/" (uri-encode id)) parse-edge-device))

(define (edge-command-status client id)
  (unless (edge-id? id)
    (raise-argument-error 'edge-command-status "bounded command ID" id))
  (request client (string-append "/v1/commands/" (uri-encode id)) parse-edge-command))

(define (edge-submit-command client attempt)
  (unless (edge-command-attempt? attempt)
    (raise-argument-error 'edge-submit-command "edge-command-attempt?" attempt))
  (request client "/v1/commands" parse-edge-command-response #:method 'post #:attempt attempt))

(define (edge-open-events client)
  (request client "/v1/events" values #:events? #t))
