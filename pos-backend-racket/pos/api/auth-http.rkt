#lang racket

(require racket/string
         web-server/http
         "http-response.rkt"
         "../application/authentication-service.rkt"
         "../domain/operator-identity.rkt"
         "../persistence/strict-json.rkt"
         "../security/authorization-policy.rkt"
         "../security/operator-session.rkt")

(provide handle-login-request
         handle-session-request
         handle-logout-request
         handle-change-pin-request
         authenticate-protected-request)

(define no-store-header (header #"Cache-Control" #"no-store"))
(define bearer-challenge-header (header #"WWW-Authenticate" #"Bearer"))

(define (auth-json-response value
                            #:status [status 200]
                            #:message [message #"OK"]
                            #:headers [headers '()])
  (json-response value
                 #:status status
                 #:message message
                 #:headers (cons no-store-header headers)))

(define (authentication-failed-response)
  (auth-json-response
   (hasheq 'ok #f
           'error
           (hasheq 'code "authentication_failed"
                   'message "Operator sign-in failed."))
   #:status 401
   #:message #"Unauthorized"))

(define (authentication-required-response)
  (auth-json-response
   (hasheq 'ok #f
           'error
           (hasheq 'code "authentication_required"
                   'message "Operator authentication is required."))
   #:status 401
   #:message #"Unauthorized"
   #:headers (list bearer-challenge-header)))

(define (authentication-unavailable-response)
  (auth-json-response
   (hasheq 'ok #f
           'error
           (hasheq 'code "authentication_unavailable"
                   'message "Operator authentication is temporarily unavailable."))
   #:status 503
   #:message #"Service Unavailable"))

(define (invalid-login-request-response code message status status-message)
  (auth-json-response
   (hasheq 'ok #f 'error (hasheq 'code code 'message message))
   #:status status
   #:message status-message))

(define (json-content-type? req)
  (define content-type
    (headers-assq* #"Content-Type" (request-headers/raw req)))
  (and content-type
       (let ([parts
              (string-split
               (bytes->string/latin-1 (header-value content-type)) ";")])
         (and (pair? parts)
              (string=?
               (string-downcase (string-trim (first parts)))
               "application/json")))))

(define (decode-login-request req)
  (cond
    [(not (json-content-type? req)) 'unsupported-media-type]
    [else
     (define bytes (request-post-data/raw req))
     (cond
       [(or (not bytes) (zero? (bytes-length bytes))) 'invalid]
       [else
        (define decoded (strict-json-bytes->jsexpr bytes))
        (cond
          [(strict-json-failure? decoded) 'invalid]
          [else
           (define object (strict-json-success-value decoded))
           (if (and (hash? object)
                    (= (hash-count object) 2)
                    (hash-has-key? object 'operator_id)
                    (hash-has-key? object 'pin)
                    (string? (hash-ref object 'operator_id))
                    (string? (hash-ref object 'pin)))
               object
               'invalid)])])]))

(define (principal->jsexpr principal absolute-expires-at-epoch-ms)
  (hasheq
   'operator_id (authenticated-operator-operator-id principal)
   'display_name (authenticated-operator-display-name principal)
   'role (operator-role->string (authenticated-operator-role principal))
   'permissions
   (operator-role-permission-strings
    (authenticated-operator-role principal))
   'idle_timeout_seconds (quotient operator-session-idle-timeout-ms 1000)
   'absolute_expires_at_epoch_ms absolute-expires-at-epoch-ms))

(define (handle-login-request service req)
  (define decoded (decode-login-request req))
  (cond
    [(eq? decoded 'unsupported-media-type)
     (invalid-login-request-response
      "unsupported_media_type"
      "Content-Type must be application/json."
      415
      #"Unsupported Media Type")]
    [(eq? decoded 'invalid)
     (invalid-login-request-response
      "invalid_login_request"
      "Login request is invalid."
      400
      #"Bad Request")]
    [else
     (define result
       (authentication-service-login
        service (hash-ref decoded 'operator_id) (hash-ref decoded 'pin)))
     (cond
       [(authentication-login-succeeded? result)
        (auth-json-response
         (hasheq
          'ok #t
          'access_token
          (authentication-login-succeeded-access-token result)
          'token_type "Bearer"
          'session
          (principal->jsexpr
           (authentication-login-succeeded-principal result)
           (authentication-login-succeeded-absolute-expires-at-epoch-ms
            result))))]
       [(authentication-login-failed? result)
        (authentication-failed-response)]
       [else (authentication-unavailable-response)])]))

(define (authorization-headers req)
  (for/list ([candidate (in-list (request-headers/raw req))]
             #:when
             (string-ci=?
              (bytes->string/latin-1 (header-field candidate))
              "Authorization"))
    (header-value candidate)))

(define (request-bearer-token req)
  (define values (authorization-headers req))
  (and (= (length values) 1)
       (let* ([text (bytes->string/latin-1 (first values))]
              [matched
               (regexp-match
                #px"^(?i:Bearer) (gpos_s1_[0-9a-f]{64})$"
                text)])
         (and matched (second matched)))))

(define (authenticate-protected-request service req handler)
  (define token (request-bearer-token req))
  (cond
    [(not token) (authentication-required-response)]
    [else
     (define result (authentication-service-authenticate service token))
     (cond
       [(authentication-session-authenticated? result)
        (handler token result)]
       [(authentication-session-unavailable? result)
        (authentication-unavailable-response)]
       [else (authentication-required-response)])]))

(define (handle-session-request service req)
  (authenticate-protected-request
   service req
   (lambda (_token authenticated)
     (define session
       (authentication-session-authenticated-session authenticated))
     (auth-json-response
      (hasheq
       'ok #t
       'session
       (principal->jsexpr
        (authentication-session-authenticated-principal authenticated)
        (operator-session-absolute-expires-at-epoch-ms session)))))))

(define (handle-logout-request service req)
  (authenticate-protected-request
   service req
   (lambda (token _authenticated)
     (define result (authentication-service-logout service token))
     (cond
       [(authentication-logout-succeeded? result)
        (auth-json-response (hasheq 'ok #t))]
       [(authentication-session-unavailable? result)
        (authentication-unavailable-response)]
       [else (authentication-required-response)]))))

(define (handle-change-pin-request service principal access-token req)
  (cond
    [(not (json-content-type? req))
     (invalid-login-request-response
      "unsupported_media_type" "Content-Type must be application/json."
      415 #"Unsupported Media Type")]
    [else
     (define bytes (request-post-data/raw req))
     (define parsed (and bytes (strict-json-bytes->jsexpr bytes)))
     (define body (and (strict-json-success? parsed)
                       (strict-json-success-value parsed)))
     (cond
       [(not (and (hash? body)
                  (= (hash-count body) 2)
                  (hash-has-key? body 'current_pin)
                  (hash-has-key? body 'new_pin)
                  (string? (hash-ref body 'current_pin))
                  (string? (hash-ref body 'new_pin))))
        (invalid-login-request-response
         "invalid_change_pin_request" "PIN change request is invalid."
         400 #"Bad Request")]
       [else
        (define result
          (authentication-service-change-pin
           service principal access-token
           (hash-ref body 'current_pin) (hash-ref body 'new_pin)))
        (cond
          [(authentication-pin-change-succeeded? result)
           (auth-json-response
            (hasheq 'ok #t
                    'credential_revision
                    (authentication-pin-change-succeeded-credential-revision result)
                    'reauthentication_required #t))]
          [(authentication-pin-change-policy-rejected? result)
           (invalid-login-request-response
            "pin_policy_rejected" "New PIN does not satisfy policy."
            400 #"Bad Request")]
          [(authentication-pin-change-failed? result)
           (invalid-login-request-response
            "credential_change_failed" "PIN change was not completed."
            403 #"Forbidden")]
          [else
           (invalid-login-request-response
            "credential_change_unavailable"
            "PIN change is temporarily unavailable."
            503 #"Service Unavailable")])])]))
