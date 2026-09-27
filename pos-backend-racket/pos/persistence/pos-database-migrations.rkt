#lang racket

(require (prefix-in db: db)
         "security-audit-store.rkt")

(provide current-pos-database-schema-version
         read-pos-database-migration-history
         classify-pos-database-migration-history
         validate-pos-database-schema!
         migrate-pos-database!)

(struct pos-database-migration (version name apply! validate!)
  #:transparent)

(define migration-1-name "create_transaction_events")
(define migration-2-name "create_transaction_command_receipts")
(define migration-3-name "create_catalog")
(define migration-4-name "create_tax_categories")
(define migration-5-name "create_register_operations")
(define migration-6-name "create_shift_cash_accountability")
(define migration-7-name "create_operator_identity_credentials")
(define migration-8-name "create_operator_login_throttle")
(define migration-9-name "create_transaction_command_actor_attributions")
(define migration-10-name "create_transaction_void_approvals")
(define migration-11-name "create_security_audit_ledger")
(define migration-12-name "bind_transaction_void_approvals_to_requester_credentials")
(define stream-sequence-index-name
  "transaction_events_stream_sequence_unique")

(define create-migrations-table-sql
  #<<SQL
CREATE TABLE IF NOT EXISTS pos_schema_migrations (
  version INTEGER PRIMARY KEY
    CHECK (typeof(version) = 'integer' AND version > 0),
  name TEXT NOT NULL
    CHECK (typeof(name) = 'text')
)
SQL
  )

(define create-events-table-sql
  #<<SQL
CREATE TABLE transaction_events (
  id INTEGER PRIMARY KEY,
  transaction_id TEXT NOT NULL
    CHECK (typeof(transaction_id) = 'text'),
  stream_sequence INTEGER NOT NULL
    CHECK (typeof(stream_sequence) = 'integer' AND stream_sequence > 0),
  schema_version INTEGER NOT NULL
    CHECK (typeof(schema_version) = 'integer' AND schema_version > 0),
  event_type TEXT NOT NULL
    CHECK (typeof(event_type) = 'text'),
  event_json TEXT NOT NULL
    CHECK (typeof(event_json) = 'text')
)
SQL
  )

(define create-stream-sequence-index-sql
  #<<SQL
CREATE UNIQUE INDEX transaction_events_stream_sequence_unique
ON transaction_events (transaction_id, stream_sequence)
SQL
  )

(define create-command-receipts-table-sql
  #<<SQL
CREATE TABLE transaction_command_receipts (
  command_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  transaction_id TEXT NOT NULL
    CHECK (
      typeof(transaction_id) = 'text'
      AND length(transaction_id) > 0
    ),
  command_schema_version INTEGER NOT NULL
    CHECK (
      typeof(command_schema_version) = 'integer'
      AND command_schema_version > 0
    ),
  command_type TEXT NOT NULL
    CHECK (
      typeof(command_type) = 'text'
      AND length(command_type) > 0
    ),
  expected_version INTEGER NOT NULL
    CHECK (
      typeof(expected_version) = 'integer'
      AND expected_version >= 0
    ),
  command_json TEXT NOT NULL
    CHECK (
      typeof(command_json) = 'text'
    ),
  outcome_kind TEXT NOT NULL
    CHECK (
      typeof(outcome_kind) = 'text'
      AND outcome_kind IN (
        'accepted',
        'domain_rejected',
        'not_found',
        'already_exists',
        'version_conflict'
      )
    ),
  outcome_code TEXT NOT NULL
    CHECK (
      typeof(outcome_code) = 'text'
      AND length(outcome_code) > 0
    ),
  outcome_stream_version INTEGER NOT NULL
    CHECK (
      typeof(outcome_stream_version) = 'integer'
      AND outcome_stream_version >= 0
    )
)
SQL
  )

(define create-catalog-items-table-sql
  #<<SQL
CREATE TABLE catalog_items (
  item_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(item_id) = 'text'
      AND length(item_id) > 0
    ),
  description TEXT NOT NULL
    CHECK (
      typeof(description) = 'text'
      AND length(description) > 0
    ),
  unit_price_minor_units INTEGER NOT NULL
    CHECK (
      typeof(unit_price_minor_units) = 'integer'
      AND unit_price_minor_units >= 0
    ),
  active INTEGER NOT NULL
    CHECK (
      typeof(active) = 'integer'
      AND active IN (0, 1)
    )
)
SQL
  )

(define create-catalog-barcodes-table-sql
  #<<SQL
CREATE TABLE catalog_barcodes (
  barcode TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(barcode) = 'text'
      AND length(barcode) > 0
    ),
  item_id TEXT NOT NULL
    CHECK (
      typeof(item_id) = 'text'
      AND length(item_id) > 0
    )
)
SQL
  )

(define create-tax-categories-table-sql
  #<<SQL
CREATE TABLE tax_categories (
  tax_category_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(tax_category_id) = 'text'
      AND length(tax_category_id) > 0
    ),
  description TEXT NOT NULL
    CHECK (
      typeof(description) = 'text'
      AND length(description) > 0
    ),
  rate_millionths INTEGER NOT NULL
    CHECK (
      typeof(rate_millionths) = 'integer'
      AND rate_millionths >= 0
      AND rate_millionths <= 1000000
    )
)
SQL
  )

(define create-catalog-item-tax-categories-table-sql
  #<<SQL
CREATE TABLE catalog_item_tax_categories (
  item_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(item_id) = 'text'
      AND length(item_id) > 0
    ),
  tax_category_id TEXT NOT NULL
    CHECK (
      typeof(tax_category_id) = 'text'
      AND length(tax_category_id) > 0
    )
)
SQL
  )

(define create-register-configuration-table-sql
  #<<SQL
CREATE TABLE register_configuration (
  singleton_id INTEGER PRIMARY KEY
    CHECK (
      typeof(singleton_id) = 'integer'
      AND singleton_id = 1
    ),
  register_id TEXT NOT NULL
    CHECK (
      typeof(register_id) = 'text'
      AND length(register_id) > 0
    ),
  display_name TEXT NOT NULL
    CHECK (
      typeof(display_name) = 'text'
      AND length(display_name) > 0
    )
)
SQL
  )

(define create-register-id-index-sql
  #<<SQL
CREATE UNIQUE INDEX register_configuration_register_id_unique
ON register_configuration (register_id)
SQL
  )

(define create-cashiers-table-sql
  #<<SQL
CREATE TABLE cashiers (
  cashier_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(cashier_id) = 'text'
      AND length(cashier_id) > 0
    ),
  display_name TEXT NOT NULL
    CHECK (
      typeof(display_name) = 'text'
      AND length(display_name) > 0
    ),
  active INTEGER NOT NULL
    CHECK (
      typeof(active) = 'integer'
      AND active IN (0, 1)
    )
)
SQL
  )

(define create-register-shifts-table-sql
  #<<SQL
CREATE TABLE register_shifts (
  shift_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(shift_id) = 'text'
      AND length(shift_id) > 0
    ),
  register_id TEXT NOT NULL
    CHECK (
      typeof(register_id) = 'text'
      AND length(register_id) > 0
    ),
  register_display_name TEXT NOT NULL
    CHECK (
      typeof(register_display_name) = 'text'
      AND length(register_display_name) > 0
    ),
  cashier_id TEXT NOT NULL
    CHECK (
      typeof(cashier_id) = 'text'
      AND length(cashier_id) > 0
    ),
  cashier_display_name TEXT NOT NULL
    CHECK (
      typeof(cashier_display_name) = 'text'
      AND length(cashier_display_name) > 0
    ),
  opened_at_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(opened_at_epoch_ms) = 'integer'
      AND opened_at_epoch_ms >= 0
    ),
  closed_at_epoch_ms INTEGER
    CHECK (
      closed_at_epoch_ms IS NULL
      OR (
        typeof(closed_at_epoch_ms) = 'integer'
        AND closed_at_epoch_ms >= opened_at_epoch_ms
      )
    ),
  active_transaction_id TEXT
    CHECK (
      active_transaction_id IS NULL
      OR (
        typeof(active_transaction_id) = 'text'
        AND length(active_transaction_id) > 0
      )
    ),
  CHECK (
    closed_at_epoch_ms IS NULL
    OR active_transaction_id IS NULL
  )
)
SQL
  )

(define create-open-shift-index-sql
  #<<SQL
CREATE UNIQUE INDEX register_shifts_one_open_per_register
ON register_shifts (register_id)
WHERE closed_at_epoch_ms IS NULL
SQL
  )

(define create-active-transaction-index-sql
  #<<SQL
CREATE UNIQUE INDEX register_shifts_active_transaction_unique
ON register_shifts (active_transaction_id)
WHERE active_transaction_id IS NOT NULL
SQL
  )

(define create-shift-cash-movements-table-sql
  #<<SQL
CREATE TABLE shift_cash_movements (
  id INTEGER PRIMARY KEY,
  shift_id TEXT NOT NULL
    CHECK (
      typeof(shift_id) = 'text'
      AND length(shift_id) > 0
    ),
  movement_sequence INTEGER NOT NULL
    CHECK (
      typeof(movement_sequence) = 'integer'
      AND movement_sequence > 0
    ),
  movement_type TEXT NOT NULL
    CHECK (
      typeof(movement_type) = 'text'
      AND movement_type IN ('opening_float', 'cash_sale')
    ),
  amount_minor_units INTEGER NOT NULL
    CHECK (
      typeof(amount_minor_units) = 'integer'
      AND amount_minor_units >= 0
    ),
  transaction_id TEXT
    CHECK (
      transaction_id IS NULL
      OR (
        typeof(transaction_id) = 'text'
        AND length(transaction_id) > 0
      )
    ),
  recorded_at_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(recorded_at_epoch_ms) = 'integer'
      AND recorded_at_epoch_ms >= 0
    ),
  CHECK (
    (movement_type = 'opening_float' AND transaction_id IS NULL)
    OR
    (movement_type = 'cash_sale' AND transaction_id IS NOT NULL)
  )
)
SQL
  )

(define create-shift-cash-reconciliations-table-sql
  #<<SQL
CREATE TABLE shift_cash_reconciliations (
  shift_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(shift_id) = 'text'
      AND length(shift_id) > 0
    ),
  expected_cash_minor_units INTEGER NOT NULL
    CHECK (
      typeof(expected_cash_minor_units) = 'integer'
      AND expected_cash_minor_units >= 0
    ),
  counted_cash_minor_units INTEGER NOT NULL
    CHECK (
      typeof(counted_cash_minor_units) = 'integer'
      AND counted_cash_minor_units >= 0
    ),
  over_short_minor_units INTEGER NOT NULL
    CHECK (
      typeof(over_short_minor_units) = 'integer'
    ),
  CHECK (
    over_short_minor_units =
      counted_cash_minor_units - expected_cash_minor_units
  )
)
SQL
  )

(define create-shift-movement-sequence-index-sql
  #<<SQL
CREATE UNIQUE INDEX shift_cash_movements_shift_sequence_unique
ON shift_cash_movements (shift_id, movement_sequence)
SQL
  )

(define create-shift-opening-index-sql
  #<<SQL
CREATE UNIQUE INDEX shift_cash_movements_one_opening_unique
ON shift_cash_movements (shift_id)
WHERE movement_type = 'opening_float'
SQL
  )

(define create-cash-sale-transaction-index-sql
  #<<SQL
CREATE UNIQUE INDEX shift_cash_movements_cash_sale_transaction_unique
ON shift_cash_movements (transaction_id)
WHERE movement_type = 'cash_sale'
SQL
  )

(define create-operators-table-sql
  #<<SQL
CREATE TABLE operators (
  operator_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(operator_id) = 'text'
      AND length(operator_id) > 0
    ),
  display_name TEXT NOT NULL
    CHECK (
      typeof(display_name) = 'text'
      AND length(display_name) > 0
    ),
  active INTEGER NOT NULL
    CHECK (
      typeof(active) = 'integer'
      AND active IN (0, 1)
    )
)
SQL
  )

(define create-operator-roles-table-sql
  #<<SQL
CREATE TABLE operator_roles (
  operator_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(operator_id) = 'text'
      AND length(operator_id) > 0
    ),
  role TEXT NOT NULL
    CHECK (
      typeof(role) = 'text'
      AND role IN ('cashier', 'supervisor', 'manager')
    ),
  FOREIGN KEY (operator_id)
    REFERENCES operators(operator_id)
    ON DELETE CASCADE
)
SQL
  )

(define create-operator-pin-credentials-table-sql
  #<<SQL
CREATE TABLE operator_pin_credentials (
  operator_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(operator_id) = 'text'
      AND length(operator_id) > 0
    ),
  password_hash TEXT NOT NULL
    CHECK (
      typeof(password_hash) = 'text'
      AND length(password_hash) > 0
      AND substr(password_hash, 1, 10) = '$argon2id$'
    ),
  credential_revision INTEGER NOT NULL
    CHECK (
      typeof(credential_revision) = 'integer'
      AND credential_revision >= 1
    ),
  FOREIGN KEY (operator_id)
    REFERENCES operators(operator_id)
    ON DELETE CASCADE
)
SQL
  )

(define create-operator-login-throttle-table-sql
  #<<SQL
CREATE TABLE operator_login_throttle (
  operator_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(operator_id) = 'text'
      AND length(operator_id) > 0
    ),
  consecutive_failures INTEGER NOT NULL
    CHECK (
      typeof(consecutive_failures) = 'integer'
      AND consecutive_failures >= 1
    ),
  last_failed_at_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(last_failed_at_epoch_ms) = 'integer'
      AND last_failed_at_epoch_ms >= 0
    ),
  blocked_until_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(blocked_until_epoch_ms) = 'integer'
      AND blocked_until_epoch_ms >= 0
      AND blocked_until_epoch_ms >= last_failed_at_epoch_ms
    ),
  FOREIGN KEY (operator_id)
    REFERENCES operators(operator_id)
    ON DELETE CASCADE
)
SQL
  )

(define create-transaction-command-actor-attributions-table-sql
  #<<SQL
CREATE TABLE transaction_command_actor_attributions (
  command_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  operator_id TEXT NOT NULL
    CHECK (
      typeof(operator_id) = 'text'
      AND length(operator_id) > 0
    ),
  FOREIGN KEY (command_id)
    REFERENCES transaction_command_receipts(command_id)
    ON DELETE CASCADE
)
SQL
  )

(define create-transaction-command-legacy-unattributed-receipts-table-sql
  #<<SQL
CREATE TABLE transaction_command_legacy_unattributed_receipts (
  command_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  FOREIGN KEY (command_id)
    REFERENCES transaction_command_receipts(command_id)
    ON DELETE CASCADE
)
SQL
  )

(define create-transaction-void-approval-grants-table-sql
  #<<SQL
CREATE TABLE transaction_void_approval_grants (
  approval_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(approval_id) = 'text'
      AND length(approval_id) > 0
    ),
  token_digest BLOB NOT NULL UNIQUE
    CHECK (
      typeof(token_digest) = 'blob'
      AND length(token_digest) = 32
    ),
  issuer_instance_id TEXT NOT NULL
    CHECK (
      typeof(issuer_instance_id) = 'text'
      AND length(issuer_instance_id) > 0
    ),
  requester_operator_id TEXT NOT NULL
    CHECK (
      typeof(requester_operator_id) = 'text'
      AND length(requester_operator_id) > 0
    ),
  approver_operator_id TEXT NOT NULL
    CHECK (
      typeof(approver_operator_id) = 'text'
      AND length(approver_operator_id) > 0
    ),
  approver_credential_revision INTEGER NOT NULL
    CHECK (
      typeof(approver_credential_revision) = 'integer'
      AND approver_credential_revision >= 1
    ),
  command_id TEXT NOT NULL UNIQUE
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  transaction_id TEXT NOT NULL
    CHECK (
      typeof(transaction_id) = 'text'
      AND length(transaction_id) > 0
    ),
  command_schema_version INTEGER NOT NULL
    CHECK (
      typeof(command_schema_version) = 'integer'
      AND command_schema_version = 1
    ),
  expected_version INTEGER NOT NULL
    CHECK (
      typeof(expected_version) = 'integer'
      AND expected_version >= 0
    ),
  granted_at_monotonic_ms INTEGER NOT NULL
    CHECK (
      typeof(granted_at_monotonic_ms) = 'integer'
      AND granted_at_monotonic_ms >= 0
    ),
  expires_at_monotonic_ms INTEGER NOT NULL
    CHECK (
      typeof(expires_at_monotonic_ms) = 'integer'
      AND expires_at_monotonic_ms > granted_at_monotonic_ms
    ),
  expires_at_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(expires_at_epoch_ms) = 'integer'
      AND expires_at_epoch_ms >= 0
    ),
  CHECK (requester_operator_id <> approver_operator_id)
)
SQL
  )

;; v12 deliberately rebuilds only unconsumed, process-bound capabilities.
;; The v10 definition above remains frozen for historical-prefix validation.
(define create-v12-transaction-void-approval-grants-table-sql
  #<<SQL
CREATE TABLE transaction_void_approval_grants (
  approval_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(approval_id) = 'text'
      AND length(approval_id) > 0
    ),
  token_digest BLOB NOT NULL UNIQUE
    CHECK (
      typeof(token_digest) = 'blob'
      AND length(token_digest) = 32
    ),
  issuer_instance_id TEXT NOT NULL
    CHECK (
      typeof(issuer_instance_id) = 'text'
      AND length(issuer_instance_id) > 0
    ),
  requester_operator_id TEXT NOT NULL
    CHECK (
      typeof(requester_operator_id) = 'text'
      AND length(requester_operator_id) > 0
    ),
  requester_credential_revision INTEGER NOT NULL
    CHECK (
      typeof(requester_credential_revision) = 'integer'
      AND requester_credential_revision >= 1
    ),
  approver_operator_id TEXT NOT NULL
    CHECK (
      typeof(approver_operator_id) = 'text'
      AND length(approver_operator_id) > 0
    ),
  approver_credential_revision INTEGER NOT NULL
    CHECK (
      typeof(approver_credential_revision) = 'integer'
      AND approver_credential_revision >= 1
    ),
  command_id TEXT NOT NULL UNIQUE
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  transaction_id TEXT NOT NULL
    CHECK (
      typeof(transaction_id) = 'text'
      AND length(transaction_id) > 0
    ),
  command_schema_version INTEGER NOT NULL
    CHECK (
      typeof(command_schema_version) = 'integer'
      AND command_schema_version = 1
    ),
  expected_version INTEGER NOT NULL
    CHECK (
      typeof(expected_version) = 'integer'
      AND expected_version >= 0
    ),
  granted_at_monotonic_ms INTEGER NOT NULL
    CHECK (
      typeof(granted_at_monotonic_ms) = 'integer'
      AND granted_at_monotonic_ms >= 0
    ),
  expires_at_monotonic_ms INTEGER NOT NULL
    CHECK (
      typeof(expires_at_monotonic_ms) = 'integer'
      AND expires_at_monotonic_ms > granted_at_monotonic_ms
    ),
  expires_at_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(expires_at_epoch_ms) = 'integer'
      AND expires_at_epoch_ms >= 0
    ),
  CHECK (requester_operator_id <> approver_operator_id)
)
SQL
  )

(define create-transaction-command-approver-attributions-table-sql
  #<<SQL
CREATE TABLE transaction_command_approver_attributions (
  command_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  approval_id TEXT NOT NULL UNIQUE
    CHECK (
      typeof(approval_id) = 'text'
      AND length(approval_id) > 0
    ),
  approver_operator_id TEXT NOT NULL
    CHECK (
      typeof(approver_operator_id) = 'text'
      AND length(approver_operator_id) > 0
    ),
  approver_credential_revision INTEGER NOT NULL
    CHECK (
      typeof(approver_credential_revision) = 'integer'
      AND approver_credential_revision >= 1
    ),
  approved_at_epoch_ms INTEGER NOT NULL
    CHECK (
      typeof(approved_at_epoch_ms) = 'integer'
      AND approved_at_epoch_ms >= 0
    ),
  FOREIGN KEY (command_id)
    REFERENCES transaction_command_receipts(command_id)
    ON DELETE CASCADE
)
SQL
  )

(define create-transaction-command-legacy-unapproved-void-receipts-table-sql
  #<<SQL
CREATE TABLE transaction_command_legacy_unapproved_void_receipts (
  command_id TEXT PRIMARY KEY NOT NULL
    CHECK (
      typeof(command_id) = 'text'
      AND length(command_id) > 0
    ),
  FOREIGN KEY (command_id)
    REFERENCES transaction_command_receipts(command_id)
    ON DELETE CASCADE
)
SQL
  )

(define create-security-audit-events-table-sql
  #<<SQL
CREATE TABLE security_audit_events (
  sequence INTEGER PRIMARY KEY
    CHECK (typeof(sequence) = 'integer' AND sequence > 0),
  schema_version INTEGER NOT NULL
    CHECK (typeof(schema_version) = 'integer' AND schema_version = 1),
  occurred_at_epoch_ms INTEGER NOT NULL
    CHECK (typeof(occurred_at_epoch_ms) = 'integer' AND occurred_at_epoch_ms >= 0),
  source_kind TEXT NOT NULL
    CHECK (typeof(source_kind) = 'text' AND source_kind IN ('pos_core', 'root_cli')),
  source_instance_id TEXT NOT NULL
    CHECK (typeof(source_instance_id) = 'text' AND length(source_instance_id) > 0),
  event_type TEXT NOT NULL
    CHECK (typeof(event_type) = 'text' AND length(event_type) > 0),
  event_json TEXT NOT NULL
    CHECK (typeof(event_json) = 'text'),
  previous_event_hash BLOB NOT NULL
    CHECK (typeof(previous_event_hash) = 'blob' AND length(previous_event_hash) = 32),
  event_hash BLOB NOT NULL UNIQUE
    CHECK (typeof(event_hash) = 'blob' AND length(event_hash) = 32)
)
SQL
  )

(define create-security-audit-events-append-order-trigger-sql
  #<<SQL
CREATE TRIGGER security_audit_events_append_order
BEFORE INSERT ON security_audit_events
BEGIN
  SELECT CASE
    WHEN NEW.sequence <> COALESCE((SELECT MAX(sequence) FROM security_audit_events), 0) + 1
    THEN RAISE(ABORT, 'security audit sequence is not append-only')
  END;
  SELECT CASE
    WHEN NEW.previous_event_hash <> COALESCE(
      (SELECT event_hash FROM security_audit_events ORDER BY sequence DESC LIMIT 1),
      zeroblob(32))
    THEN RAISE(ABORT, 'security audit previous hash does not match tail')
  END;
END
SQL
  )

(define create-security-audit-events-no-update-trigger-sql
  #<<SQL
CREATE TRIGGER security_audit_events_no_update
BEFORE UPDATE ON security_audit_events
BEGIN
  SELECT RAISE(ABORT, 'security audit events are append-only');
END
SQL
  )

(define create-security-audit-events-no-delete-trigger-sql
  #<<SQL
CREATE TRIGGER security_audit_events_no_delete
BEFORE DELETE ON security_audit_events
BEGIN
  SELECT RAISE(ABORT, 'security audit events are append-only');
END
SQL
  )

(define (schema-object-exists? connection type name)
  (= 1
     (db:query-value
      connection
      #<<SQL
SELECT COUNT(*)
FROM sqlite_schema
WHERE type = ? AND name = ?
SQL
      type
      name)))

(define (validate-events-schema connection)
  (unless (schema-object-exists? connection "table" "transaction_events")
    (error 'migrate-pos-database!
           "migration 1 is recorded but transaction_events is missing"))
  (define stream-index-row
    (for/first ([row (in-list
                      (db:query-rows
                       connection
                       "PRAGMA index_list('transaction_events')"))]
                #:when (equal? (vector-ref row 1)
                               stream-sequence-index-name))
      row))
  (unless stream-index-row
    (error 'migrate-pos-database!
           "migration 1 is recorded but its stream index is missing"))
  (unless (= (vector-ref stream-index-row 2) 1)
    (error 'migrate-pos-database!
           "journal stream index must be unique"))
  (define stream-index-columns
    (for/list ([row (in-list
                     (db:query-rows
                      connection
                      (format "PRAGMA index_info('~a')"
                              stream-sequence-index-name)))])
      (vector-ref row 2)))
  (unless (equal? stream-index-columns
                  '("transaction_id" "stream_sequence"))
    (error 'migrate-pos-database!
           "journal stream index has unexpected columns: ~e"
           stream-index-columns)))

(define expected-command-receipt-columns
  (list (vector "command_id" "TEXT" 1 1)
        (vector "transaction_id" "TEXT" 1 0)
        (vector "command_schema_version" "INTEGER" 1 0)
        (vector "command_type" "TEXT" 1 0)
        (vector "expected_version" "INTEGER" 1 0)
        (vector "command_json" "TEXT" 1 0)
        (vector "outcome_kind" "TEXT" 1 0)
        (vector "outcome_code" "TEXT" 1 0)
        (vector "outcome_stream_version" "INTEGER" 1 0)))

(define (normalize-schema-sql sql)
  (string-downcase
   (string-trim (regexp-replace* #px"\\s+" sql " "))))

(define (validate-command-receipts-schema connection)
  (unless (schema-object-exists?
           connection "table" "transaction_command_receipts")
    (error 'migrate-pos-database!
           "migration 2 is recorded but transaction_command_receipts is missing"))

  (define actual-columns
    (for/list ([row (in-list
                     (db:query-rows
                      connection
                      "PRAGMA table_info('transaction_command_receipts')"))])
      (vector (vector-ref row 1)
              (string-upcase (vector-ref row 2))
              (vector-ref row 3)
              (vector-ref row 5))))
  (unless (equal? actual-columns expected-command-receipt-columns)
    (error 'migrate-pos-database!
           "transaction command receipt table has unexpected columns: ~e"
           actual-columns))

  ;; PRAGMA table_info does not expose CHECK expressions. Since this table is
  ;; owned exclusively by migration 2, compare normalized migration DDL to
  ;; detect constraint drift without attempting to parse arbitrary SQL.
  (define recorded-sql
    (db:query-value
     connection
     #<<SQL
SELECT sql
FROM sqlite_schema
WHERE type = 'table' AND name = 'transaction_command_receipts'
SQL
     ))
  (unless (string=? (normalize-schema-sql recorded-sql)
                    (normalize-schema-sql
                     create-command-receipts-table-sql))
    (error 'migrate-pos-database!
           "transaction command receipt table definition has drifted")))

(define expected-catalog-item-columns
  (list (vector "item_id" "TEXT" 1 1)
        (vector "description" "TEXT" 1 0)
        (vector "unit_price_minor_units" "INTEGER" 1 0)
        (vector "active" "INTEGER" 1 0)))

(define expected-catalog-barcode-columns
  (list (vector "barcode" "TEXT" 1 1)
        (vector "item_id" "TEXT" 1 0)))

(define expected-tax-category-columns
  (list (vector "tax_category_id" "TEXT" 1 1)
        (vector "description" "TEXT" 1 0)
        (vector "rate_millionths" "INTEGER" 1 0)))

(define expected-catalog-item-tax-category-columns
  (list (vector "item_id" "TEXT" 1 1)
        (vector "tax_category_id" "TEXT" 1 0)))

(define expected-register-configuration-columns
  (list (vector "singleton_id" "INTEGER" 0 1)
        (vector "register_id" "TEXT" 1 0)
        (vector "display_name" "TEXT" 1 0)))

(define expected-cashier-columns
  (list (vector "cashier_id" "TEXT" 1 1)
        (vector "display_name" "TEXT" 1 0)
        (vector "active" "INTEGER" 1 0)))

(define expected-register-shift-columns
  (list (vector "shift_id" "TEXT" 1 1)
        (vector "register_id" "TEXT" 1 0)
        (vector "register_display_name" "TEXT" 1 0)
        (vector "cashier_id" "TEXT" 1 0)
        (vector "cashier_display_name" "TEXT" 1 0)
        (vector "opened_at_epoch_ms" "INTEGER" 1 0)
        (vector "closed_at_epoch_ms" "INTEGER" 0 0)
        (vector "active_transaction_id" "TEXT" 0 0)))

(define expected-shift-cash-movement-columns
  (list (vector "id" "INTEGER" 0 1)
        (vector "shift_id" "TEXT" 1 0)
        (vector "movement_sequence" "INTEGER" 1 0)
        (vector "movement_type" "TEXT" 1 0)
        (vector "amount_minor_units" "INTEGER" 1 0)
        (vector "transaction_id" "TEXT" 0 0)
        (vector "recorded_at_epoch_ms" "INTEGER" 1 0)))

(define expected-shift-cash-reconciliation-columns
  (list (vector "shift_id" "TEXT" 1 1)
        (vector "expected_cash_minor_units" "INTEGER" 1 0)
        (vector "counted_cash_minor_units" "INTEGER" 1 0)
        (vector "over_short_minor_units" "INTEGER" 1 0)))

(define expected-operator-columns
  (list (vector "operator_id" "TEXT" 1 1)
        (vector "display_name" "TEXT" 1 0)
        (vector "active" "INTEGER" 1 0)))

(define expected-operator-role-columns
  (list (vector "operator_id" "TEXT" 1 1)
        (vector "role" "TEXT" 1 0)))

(define expected-operator-pin-credential-columns
  (list (vector "operator_id" "TEXT" 1 1)
        (vector "password_hash" "TEXT" 1 0)
        (vector "credential_revision" "INTEGER" 1 0)))

(define expected-operator-login-throttle-columns
  (list (vector "operator_id" "TEXT" 1 1)
        (vector "consecutive_failures" "INTEGER" 1 0)
        (vector "last_failed_at_epoch_ms" "INTEGER" 1 0)
        (vector "blocked_until_epoch_ms" "INTEGER" 1 0)))

(define expected-transaction-command-actor-attribution-columns
  (list (vector "command_id" "TEXT" 1 1)
        (vector "operator_id" "TEXT" 1 0)))

(define expected-transaction-command-legacy-unattributed-receipt-columns
  (list (vector "command_id" "TEXT" 1 1)))

(define expected-transaction-void-approval-grant-columns
  (list (vector "approval_id" "TEXT" 1 1)
        (vector "token_digest" "BLOB" 1 0)
        (vector "issuer_instance_id" "TEXT" 1 0)
        (vector "requester_operator_id" "TEXT" 1 0)
        (vector "approver_operator_id" "TEXT" 1 0)
        (vector "approver_credential_revision" "INTEGER" 1 0)
        (vector "command_id" "TEXT" 1 0)
        (vector "transaction_id" "TEXT" 1 0)
        (vector "command_schema_version" "INTEGER" 1 0)
        (vector "expected_version" "INTEGER" 1 0)
        (vector "granted_at_monotonic_ms" "INTEGER" 1 0)
        (vector "expires_at_monotonic_ms" "INTEGER" 1 0)
        (vector "expires_at_epoch_ms" "INTEGER" 1 0)))

(define expected-v12-transaction-void-approval-grant-columns
  (append (take expected-transaction-void-approval-grant-columns 4)
          (list (vector "requester_credential_revision" "INTEGER" 1 0))
          (drop expected-transaction-void-approval-grant-columns 4)))

(define expected-transaction-command-approver-attribution-columns
  (list (vector "command_id" "TEXT" 1 1)
        (vector "approval_id" "TEXT" 1 0)
        (vector "approver_operator_id" "TEXT" 1 0)
        (vector "approver_credential_revision" "INTEGER" 1 0)
        (vector "approved_at_epoch_ms" "INTEGER" 1 0)))

(define expected-transaction-command-legacy-unapproved-void-receipt-columns
  (list (vector "command_id" "TEXT" 1 1)))

(define expected-security-audit-event-columns
  (list (vector "sequence" "INTEGER" 0 1)
        (vector "schema_version" "INTEGER" 1 0)
        (vector "occurred_at_epoch_ms" "INTEGER" 1 0)
        (vector "source_kind" "TEXT" 1 0)
        (vector "source_instance_id" "TEXT" 1 0)
        (vector "event_type" "TEXT" 1 0)
        (vector "event_json" "TEXT" 1 0)
        (vector "previous_event_hash" "BLOB" 1 0)
        (vector "event_hash" "BLOB" 1 0)))

(define (validate-owned-table-schema connection
                                     migration-version
                                     table-name
                                     expected-columns
                                     expected-sql)
  (unless (schema-object-exists? connection "table" table-name)
    (error 'migrate-pos-database!
           "migration ~a is recorded but ~a is missing"
           migration-version
           table-name))

  (define actual-columns
    (for/list ([row (in-list
                     (db:query-rows
                      connection
                      (format "PRAGMA table_info('~a')" table-name)))])
      (vector (vector-ref row 1)
              (string-upcase (vector-ref row 2))
              (vector-ref row 3)
              (vector-ref row 5))))
  (unless (equal? actual-columns expected-columns)
    (error 'migrate-pos-database!
           "~a has unexpected columns: ~e"
           table-name
           actual-columns))

  ;; Each table passed here is wholly owned by its creating migration.
  ;; Comparing normalized DDL catches CHECK-constraint drift that PRAGMA
  ;; table_info does not expose without pretending to parse arbitrary SQL.
  (define recorded-sql
    (db:query-value
     connection
     #<<SQL
SELECT sql
FROM sqlite_schema
WHERE type = 'table' AND name = ?
SQL
     table-name))
  (unless (string=? (normalize-schema-sql recorded-sql)
                    (normalize-schema-sql expected-sql))
    (error 'migrate-pos-database!
           "~a definition has drifted"
           table-name)))

(define (validate-catalog-schema connection)
  (validate-owned-table-schema connection
                               3
                               "catalog_items"
                               expected-catalog-item-columns
                               create-catalog-items-table-sql)
  (validate-owned-table-schema connection
                               3
                               "catalog_barcodes"
                               expected-catalog-barcode-columns
                               create-catalog-barcodes-table-sql))

(define (validate-tax-reference-integrity connection)
  (define unmapped-item-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_items AS item
LEFT JOIN catalog_item_tax_categories AS mapping
  ON mapping.item_id = item.item_id
WHERE mapping.item_id IS NULL
SQL
     ))
  (define orphan-item-mapping-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_item_tax_categories AS mapping
LEFT JOIN catalog_items AS item
  ON item.item_id = mapping.item_id
WHERE item.item_id IS NULL
SQL
     ))
  (define orphan-category-mapping-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM catalog_item_tax_categories AS mapping
LEFT JOIN tax_categories AS category
  ON category.tax_category_id = mapping.tax_category_id
WHERE category.tax_category_id IS NULL
SQL
     ))
  (unless (zero? unmapped-item-count)
    (error 'migrate-pos-database!
           "catalog contains items without a tax category mapping"))
  (unless (zero? orphan-item-mapping-count)
    (error 'migrate-pos-database!
           "catalog tax mappings contain missing items"))
  (unless (zero? orphan-category-mapping-count)
    (error 'migrate-pos-database!
           "catalog tax mappings contain missing tax categories")))

(define (validate-tax-categories-schema connection)
  (validate-owned-table-schema connection
                               4
                               "tax_categories"
                               expected-tax-category-columns
                               create-tax-categories-table-sql)
  (validate-owned-table-schema
   connection
   4
   "catalog_item_tax_categories"
   expected-catalog-item-tax-category-columns
   create-catalog-item-tax-categories-table-sql)
  (validate-tax-reference-integrity connection))

(define (validate-owned-index-schema connection
                                     migration-version
                                     index-name
                                     expected-sql)
  (unless (schema-object-exists? connection "index" index-name)
    (error 'migrate-pos-database!
           "migration ~a is recorded but index ~a is missing"
           migration-version
           index-name))
  (define recorded-sql
    (db:query-value
     connection
     "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?"
     index-name))
  (unless (and recorded-sql
               (string=? (normalize-schema-sql recorded-sql)
                         (normalize-schema-sql expected-sql)))
    (error 'migrate-pos-database!
           "~a definition has drifted"
           index-name)))

(define (validate-owned-trigger-schema connection name expected-sql)
  (unless (schema-object-exists? connection "trigger" name)
    (error 'migrate-pos-database! "security audit trigger is missing: ~a" name))
  (define recorded-sql
    (db:query-value
     connection
     "SELECT sql FROM sqlite_schema WHERE type = 'trigger' AND name = ?"
     name))
  (unless (string=? (normalize-schema-sql recorded-sql)
                    (normalize-schema-sql expected-sql))
    (error 'migrate-pos-database! "security audit trigger has drifted: ~a" name)))

(define (validate-register-operations-schema connection)
  (validate-owned-table-schema
   connection
   5
   "register_configuration"
   expected-register-configuration-columns
   create-register-configuration-table-sql)
  (validate-owned-table-schema
   connection
   5
   "cashiers"
   expected-cashier-columns
   create-cashiers-table-sql)
  (validate-owned-table-schema
   connection
   5
   "register_shifts"
   expected-register-shift-columns
   create-register-shifts-table-sql)
  (validate-owned-index-schema
   connection
   5
   "register_configuration_register_id_unique"
   create-register-id-index-sql)
  (validate-owned-index-schema
   connection
   5
   "register_shifts_one_open_per_register"
   create-open-shift-index-sql)
  (validate-owned-index-schema
   connection
   5
   "register_shifts_active_transaction_unique"
   create-active-transaction-index-sql))

(define (validate-shift-cash-integrity connection)
  (define orphan-movements
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM shift_cash_movements AS movement
LEFT JOIN register_shifts AS shift ON shift.shift_id = movement.shift_id
WHERE shift.shift_id IS NULL
SQL
     ))
  (define orphan-reconciliations
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM shift_cash_reconciliations AS reconciliation
LEFT JOIN register_shifts AS shift ON shift.shift_id = reconciliation.shift_id
WHERE shift.shift_id IS NULL
SQL
     ))
  (define tracked-without-one-opening
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM (
  SELECT shift_id,
         SUM(CASE WHEN movement_type = 'opening_float' THEN 1 ELSE 0 END)
           AS opening_count
  FROM shift_cash_movements
  GROUP BY shift_id
)
WHERE opening_count <> 1
SQL
     ))
  (define open-without-opening
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM register_shifts AS shift
LEFT JOIN shift_cash_movements AS movement
  ON movement.shift_id = shift.shift_id
 AND movement.movement_type = 'opening_float'
WHERE shift.closed_at_epoch_ms IS NULL
  AND movement.id IS NULL
SQL
     ))
  (define noncontiguous-ledgers
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM (
  SELECT shift_id, COUNT(*) AS movement_count,
         MIN(movement_sequence) AS minimum_sequence,
         MAX(movement_sequence) AS maximum_sequence
  FROM shift_cash_movements
  GROUP BY shift_id
)
WHERE minimum_sequence <> 1 OR maximum_sequence <> movement_count
SQL
     ))
  (define inconsistent-reconciliations
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM shift_cash_reconciliations AS reconciliation
JOIN register_shifts AS shift ON shift.shift_id = reconciliation.shift_id
LEFT JOIN (
  SELECT shift_id, SUM(amount_minor_units) AS expected_cash_minor_units
  FROM shift_cash_movements
  GROUP BY shift_id
) AS ledger ON ledger.shift_id = reconciliation.shift_id
WHERE shift.closed_at_epoch_ms IS NULL
   OR ledger.expected_cash_minor_units IS NULL
   OR reconciliation.expected_cash_minor_units <>
        ledger.expected_cash_minor_units
SQL
     ))
  (unless (zero? orphan-movements)
    (error 'migrate-pos-database! "cash movements reference missing shifts"))
  (unless (zero? orphan-reconciliations)
    (error 'migrate-pos-database!
           "cash reconciliations reference missing shifts"))
  (unless (zero? tracked-without-one-opening)
    (error 'migrate-pos-database!
           "tracked shift cash ledgers require exactly one opening movement"))
  (unless (zero? open-without-opening)
    (error 'migrate-pos-database!
           "open v6 shifts require an opening cash movement"))
  (unless (zero? noncontiguous-ledgers)
    (error 'migrate-pos-database!
           "shift cash movement sequences must be contiguous from one"))
  (unless (zero? inconsistent-reconciliations)
    (error 'migrate-pos-database!
           "shift cash reconciliation disagrees with shift or ledger state")))

(define (validate-shift-cash-accountability-schema connection)
  (validate-owned-table-schema
   connection 6 "shift_cash_movements"
   expected-shift-cash-movement-columns
   create-shift-cash-movements-table-sql)
  (validate-owned-table-schema
   connection 6 "shift_cash_reconciliations"
   expected-shift-cash-reconciliation-columns
   create-shift-cash-reconciliations-table-sql)
  (validate-owned-index-schema
   connection 6 "shift_cash_movements_shift_sequence_unique"
   create-shift-movement-sequence-index-sql)
  (validate-owned-index-schema
   connection 6 "shift_cash_movements_one_opening_unique"
   create-shift-opening-index-sql)
  (validate-owned-index-schema
   connection 6 "shift_cash_movements_cash_sale_transaction_unique"
   create-cash-sale-transaction-index-sql)
  (validate-shift-cash-integrity connection))

(define (validate-operator-relational-integrity connection)
  (define cashier-without-operator-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM cashiers AS cashier
LEFT JOIN operators AS operator
  ON operator.operator_id = cashier.cashier_id
WHERE operator.operator_id IS NULL
SQL
     ))
  (define operator-without-one-role-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM (
  SELECT operator.operator_id
  FROM operators AS operator
  LEFT JOIN operator_roles AS assignment
    ON assignment.operator_id = operator.operator_id
  GROUP BY operator.operator_id
  HAVING COUNT(assignment.operator_id) <> 1
)
SQL
     ))
  (define orphan-role-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM operator_roles AS assignment
LEFT JOIN operators AS operator
  ON operator.operator_id = assignment.operator_id
WHERE operator.operator_id IS NULL
SQL
     ))
  (define orphan-credential-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM operator_pin_credentials AS credential
LEFT JOIN operators AS operator
  ON operator.operator_id = credential.operator_id
WHERE operator.operator_id IS NULL
SQL
     ))
  (unless (zero? cashier-without-operator-count)
    (error 'migrate-pos-database!
           "current cashiers require same-ID operator principals"))
  (unless (zero? operator-without-one-role-count)
    (error 'migrate-pos-database!
           "every operator requires exactly one role"))
  (unless (zero? orphan-role-count)
    (error 'migrate-pos-database!
           "operator roles reference missing operators"))
  (unless (zero? orphan-credential-count)
    (error 'migrate-pos-database!
           "operator credentials reference missing operators")))

(define (validate-operator-identity-schema connection)
  (validate-owned-table-schema
   connection 7 "operators"
   expected-operator-columns
   create-operators-table-sql)
  (validate-owned-table-schema
   connection 7 "operator_roles"
   expected-operator-role-columns
   create-operator-roles-table-sql)
  (validate-owned-table-schema
   connection 7 "operator_pin_credentials"
   expected-operator-pin-credential-columns
   create-operator-pin-credentials-table-sql)
  (validate-operator-relational-integrity connection))

(define (validate-operator-login-throttle-schema connection)
  (validate-owned-table-schema
   connection 8 "operator_login_throttle"
   expected-operator-login-throttle-columns
   create-operator-login-throttle-table-sql)
  (define orphan-throttle-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM operator_login_throttle AS throttle
LEFT JOIN operators AS operator
  ON operator.operator_id = throttle.operator_id
WHERE operator.operator_id IS NULL
SQL
     ))
  (unless (zero? orphan-throttle-count)
    (error 'migrate-pos-database!
           "operator login throttle state references missing operators")))

(define (validate-transaction-command-actor-attributions-schema connection)
  (validate-owned-table-schema
   connection 9 "transaction_command_legacy_unattributed_receipts"
   expected-transaction-command-legacy-unattributed-receipt-columns
   create-transaction-command-legacy-unattributed-receipts-table-sql)
  (validate-owned-table-schema
   connection 9 "transaction_command_actor_attributions"
   expected-transaction-command-actor-attribution-columns
   create-transaction-command-actor-attributions-table-sql)
  (define orphan-attribution-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_actor_attributions AS attribution
LEFT JOIN transaction_command_receipts AS receipt
  ON receipt.command_id = attribution.command_id
WHERE receipt.command_id IS NULL
SQL
     ))
  (unless (zero? orphan-attribution-count)
    (error 'migrate-pos-database!
           "transaction command actor attribution references a missing receipt"))
  (define orphan-legacy-classification-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_legacy_unattributed_receipts AS legacy
LEFT JOIN transaction_command_receipts AS receipt
  ON receipt.command_id = legacy.command_id
WHERE receipt.command_id IS NULL
SQL
     ))
  (unless (zero? orphan-legacy-classification-count)
    (error 'migrate-pos-database!
           "legacy command classification references a missing receipt"))
  (define conflicting-classification-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_legacy_unattributed_receipts AS legacy
JOIN transaction_command_actor_attributions AS attribution
  ON attribution.command_id = legacy.command_id
SQL
     ))
  (unless (zero? conflicting-classification-count)
    (error 'migrate-pos-database!
           "a command receipt cannot be both legacy-unattributed and attributed"))
  (define unclassified-receipt-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_receipts AS receipt
LEFT JOIN transaction_command_legacy_unattributed_receipts AS legacy
  ON legacy.command_id = receipt.command_id
LEFT JOIN transaction_command_actor_attributions AS attribution
  ON attribution.command_id = receipt.command_id
WHERE legacy.command_id IS NULL
  AND attribution.command_id IS NULL
SQL
     ))
  (unless (zero? unclassified-receipt-count)
    (error 'migrate-pos-database!
           "every command receipt must be attributed or explicitly classified as pre-v9")))

(define (validate-transaction-void-approvals-schema connection)
  ;; The v12 validator owns the replacement DDL. Historical v10/v11 prefixes
  ;; still validate against exactly the original v10 definition.
  (unless (db:query-maybe-value
           connection
           "SELECT 1 FROM pos_schema_migrations WHERE version = 12")
    (validate-owned-table-schema
     connection 10 "transaction_void_approval_grants"
     expected-transaction-void-approval-grant-columns
     create-transaction-void-approval-grants-table-sql))
  (validate-owned-table-schema
   connection 10 "transaction_command_approver_attributions"
   expected-transaction-command-approver-attribution-columns
   create-transaction-command-approver-attributions-table-sql)
  (validate-owned-table-schema
   connection 10 "transaction_command_legacy_unapproved_void_receipts"
   expected-transaction-command-legacy-unapproved-void-receipt-columns
   create-transaction-command-legacy-unapproved-void-receipts-table-sql)
  (define orphan-approver-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_approver_attributions AS attribution
LEFT JOIN transaction_command_receipts AS receipt
  ON receipt.command_id = attribution.command_id
WHERE receipt.command_id IS NULL
SQL
     ))
  (unless (zero? orphan-approver-count)
    (error 'migrate-pos-database!
           "transaction command approver attribution references a missing receipt"))
  (define orphan-legacy-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_legacy_unapproved_void_receipts AS legacy
LEFT JOIN transaction_command_receipts AS receipt
  ON receipt.command_id = legacy.command_id
WHERE receipt.command_id IS NULL
SQL
     ))
  (unless (zero? orphan-legacy-count)
    (error 'migrate-pos-database!
           "legacy void approval classification references a missing receipt"))
  (define conflicting-void-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_legacy_unapproved_void_receipts AS legacy
JOIN transaction_command_approver_attributions AS attribution
  ON attribution.command_id = legacy.command_id
SQL
     ))
  (unless (zero? conflicting-void-count)
    (error 'migrate-pos-database!
           "a void receipt cannot be both approved and legacy-unapproved"))
  (define unclassified-void-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_receipts AS receipt
LEFT JOIN transaction_command_legacy_unapproved_void_receipts AS legacy
  ON legacy.command_id = receipt.command_id
LEFT JOIN transaction_command_approver_attributions AS attribution
  ON attribution.command_id = receipt.command_id
WHERE receipt.command_type = 'void_transaction'
  AND legacy.command_id IS NULL
  AND attribution.command_id IS NULL
SQL
     ))
  (unless (zero? unclassified-void-count)
    (error 'migrate-pos-database!
           "every void receipt must be approved or explicitly classified as pre-v10"))
  (define classified-non-void-count
    (db:query-value
     connection
     #<<SQL
SELECT COUNT(*)
FROM transaction_command_receipts AS receipt
LEFT JOIN transaction_command_legacy_unapproved_void_receipts AS legacy
  ON legacy.command_id = receipt.command_id
LEFT JOIN transaction_command_approver_attributions AS attribution
  ON attribution.command_id = receipt.command_id
WHERE receipt.command_type <> 'void_transaction'
  AND (legacy.command_id IS NOT NULL OR attribution.command_id IS NOT NULL)
SQL
     ))
  (unless (zero? classified-non-void-count)
    (error 'migrate-pos-database!
           "non-void receipts cannot carry void approval provenance")))

(define (validate-security-audit-schema connection)
  (validate-owned-table-schema
   connection 11 "security_audit_events"
   expected-security-audit-event-columns
   create-security-audit-events-table-sql)
  (validate-owned-trigger-schema
   connection "security_audit_events_append_order"
   create-security-audit-events-append-order-trigger-sql)
  (validate-owned-trigger-schema
   connection "security_audit_events_no_update"
   create-security-audit-events-no-update-trigger-sql)
  (validate-owned-trigger-schema
   connection "security_audit_events_no_delete"
   create-security-audit-events-no-delete-trigger-sql)
  (define verification (verify-security-audit-ledger connection))
  (unless (security-audit-ledger-valid? verification)
    (error 'migrate-pos-database!
           "security audit ledger failed integrity verification at sequence ~a"
           (security-audit-ledger-invalid-sequence verification))))

(define (apply-migration-1! connection)
  (db:query-exec connection create-events-table-sql)
  (db:query-exec connection create-stream-sequence-index-sql))

(define (apply-migration-2! connection)
  (db:query-exec connection create-command-receipts-table-sql))

(define (apply-migration-3! connection)
  (db:query-exec connection create-catalog-items-table-sql)
  (db:query-exec connection create-catalog-barcodes-table-sql))

(define (apply-migration-4! connection)
  (db:query-exec connection create-tax-categories-table-sql)
  (db:query-exec connection create-catalog-item-tax-categories-table-sql)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO tax_categories
  (tax_category_id, description, rate_millionths)
VALUES ('__legacy_zero_tax__', 'Legacy zero tax', 0)
SQL
   )
  (db:query-exec
   connection
   #<<SQL
INSERT INTO catalog_item_tax_categories (item_id, tax_category_id)
SELECT item_id, '__legacy_zero_tax__'
FROM catalog_items
SQL
   ))

(define (apply-migration-5! connection)
  (db:query-exec connection create-register-configuration-table-sql)
  (db:query-exec connection create-register-id-index-sql)
  (db:query-exec connection create-cashiers-table-sql)
  (db:query-exec connection create-register-shifts-table-sql)
  (db:query-exec connection create-open-shift-index-sql)
  (db:query-exec connection create-active-transaction-index-sql))

(define (apply-migration-6! connection)
  (when (positive?
         (db:query-value
          connection
          "SELECT COUNT(*) FROM register_shifts WHERE closed_at_epoch_ms IS NULL"))
    (error 'migrate-pos-database!
           "cash-accountability migration requires every v5 shift to be closed"))
  (db:query-exec connection create-shift-cash-movements-table-sql)
  (db:query-exec connection create-shift-cash-reconciliations-table-sql)
  (db:query-exec connection create-shift-movement-sequence-index-sql)
  (db:query-exec connection create-shift-opening-index-sql)
  (db:query-exec connection create-cash-sale-transaction-index-sql))

(define (apply-migration-7! connection)
  (db:query-exec connection create-operators-table-sql)
  (db:query-exec connection create-operator-roles-table-sql)
  (db:query-exec connection create-operator-pin-credentials-table-sql)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO operators (operator_id, display_name, active)
SELECT cashier_id, display_name, active
FROM cashiers
SQL
   )
  (db:query-exec
   connection
   #<<SQL
INSERT INTO operator_roles (operator_id, role)
SELECT cashier_id, 'cashier'
FROM cashiers
SQL
   ))

(define (apply-migration-8! connection)
  (db:query-exec connection create-operator-login-throttle-table-sql))

(define (apply-migration-9! connection)
  ;; Historical receipts deliberately remain unattributed because their
  ;; transaction context cannot prove which authenticated operator submitted
  ;; the command. Classify exactly the receipts present at the v9 boundary so
  ;; a missing actor on a later receipt can never inherit legacy compatibility.
  (db:query-exec
   connection
   create-transaction-command-legacy-unattributed-receipts-table-sql)
  (db:query-exec
   connection
   #<<SQL
INSERT INTO transaction_command_legacy_unattributed_receipts (command_id)
SELECT command_id
FROM transaction_command_receipts
SQL
   )
  (db:query-exec
   connection create-transaction-command-actor-attributions-table-sql))

(define (apply-migration-10! connection)
  (db:query-exec connection create-transaction-void-approval-grants-table-sql)
  (db:query-exec
   connection create-transaction-command-approver-attributions-table-sql)
  (db:query-exec
   connection create-transaction-command-legacy-unapproved-void-receipts-table-sql)
  ;; These rows are historical truth: they prove only that the void receipt
  ;; existed before CP4, never that a particular operator approved it.
  (db:query-exec
   connection
   #<<SQL
INSERT INTO transaction_command_legacy_unapproved_void_receipts (command_id)
SELECT command_id
FROM transaction_command_receipts
WHERE command_type = 'void_transaction'
SQL
   ))

(define (apply-migration-11! connection)
  ;; No historical events are inferred or fabricated at the v11 boundary.
  (db:query-exec connection create-security-audit-events-table-sql)
  (db:query-exec connection create-security-audit-events-append-order-trigger-sql)
  (db:query-exec connection create-security-audit-events-no-update-trigger-sql)
  (db:query-exec connection create-security-audit-events-no-delete-trigger-sql))

(define (apply-migration-12! connection)
  ;; A migration requires a POS Core restart. Existing unconsumed grants are
  ;; bound to that old process instance and cannot authorize future commands.
  ;; Do not copy them into the revision-bound table or invent security history.
  (db:query-exec connection "DROP TABLE transaction_void_approval_grants")
  (db:query-exec connection create-v12-transaction-void-approval-grants-table-sql))

(define (validate-v12-transaction-void-approvals-schema connection)
  (validate-owned-table-schema
   connection 12 "transaction_void_approval_grants"
   expected-v12-transaction-void-approval-grant-columns
   create-v12-transaction-void-approval-grants-table-sql))

(define migrations
  (list
   (pos-database-migration 1
                           migration-1-name
                           apply-migration-1!
                           validate-events-schema)
   (pos-database-migration 2
                           migration-2-name
                           apply-migration-2!
                           validate-command-receipts-schema)
   (pos-database-migration 3
                           migration-3-name
                           apply-migration-3!
                           validate-catalog-schema)
   (pos-database-migration 4
                           migration-4-name
                           apply-migration-4!
                           validate-tax-categories-schema)
   (pos-database-migration 5
                           migration-5-name
                           apply-migration-5!
                           validate-register-operations-schema)
   (pos-database-migration 6
                           migration-6-name
                           apply-migration-6!
                           validate-shift-cash-accountability-schema)
   (pos-database-migration 7
                           migration-7-name
                           apply-migration-7!
                           validate-operator-identity-schema)
   (pos-database-migration 8
                           migration-8-name
                           apply-migration-8!
                           validate-operator-login-throttle-schema)
   (pos-database-migration 9
                           migration-9-name
                           apply-migration-9!
                           validate-transaction-command-actor-attributions-schema)
   (pos-database-migration 10
                           migration-10-name
                           apply-migration-10!
                           validate-transaction-void-approvals-schema)
   (pos-database-migration 11
                           migration-11-name
                           apply-migration-11!
                           validate-security-audit-schema)
   (pos-database-migration 12
                           migration-12-name
                           apply-migration-12!
                           validate-v12-transaction-void-approvals-schema)))

(define current-pos-database-schema-version (length migrations))

(define (migration-row-matches? row migration)
  (and (vector? row)
       (= (vector-length row) 2)
       (equal? (vector-ref row 0)
               (pos-database-migration-version migration))
       (equal? (vector-ref row 1)
               (pos-database-migration-name migration))))

(define (valid-migration-prefix? applied-migrations)
  (and (<= (length applied-migrations) (length migrations))
       (for/and ([row (in-list applied-migrations)]
                 [migration (in-list migrations)])
         (migration-row-matches? row migration))))

(define (read-pos-database-migration-history connection)
  (unless (db:connection? connection)
    (raise-argument-error
     'read-pos-database-migration-history
     "connection?"
     connection))
  ;; This query is intentionally non-mutating. A missing migrations table is
  ;; evidence about the inspected database, not an invitation to create it.
  (db:query-rows
   connection
   "SELECT version, name FROM pos_schema_migrations ORDER BY version ASC"))

(define (classify-pos-database-migration-history history)
  (unless (list? history)
    (raise-argument-error
     'classify-pos-database-migration-history
     "list?"
     history))
  (cond
    [(not (valid-migration-prefix? history)) 'unsupported]
    [(= (length history) current-pos-database-schema-version) 'current]
    [else 'supported-prefix]))

(define (validate-applied-pos-database-schema! connection
                                                applied-migrations
                                                who)
  (when (eq? (classify-pos-database-migration-history applied-migrations)
             'unsupported)
    (error
     who
     "unsupported POS database migration history: ~e"
     applied-migrations))
  (for ([migration
         (in-list (take migrations (length applied-migrations)))])
    ((pos-database-migration-validate! migration) connection)))

(define (validate-pos-database-schema!
         connection
         #:require-current? [require-current? #f])
  (define who 'validate-pos-database-schema!)
  (unless (db:connection? connection)
    (raise-argument-error who "connection?" connection))
  (unless (boolean? require-current?)
    (raise-argument-error who "boolean?" require-current?))

  (define applied-migrations
    (read-pos-database-migration-history connection))
  (validate-applied-pos-database-schema!
   connection applied-migrations who)
  (when (and require-current?
             (not (eq? (classify-pos-database-migration-history
                        applied-migrations)
                       'current)))
    (error
     who
     "POS database schema is not current: expected version ~a, history ~e"
     current-pos-database-schema-version
     applied-migrations))
  (void))

(define (record-migration! connection migration)
  (db:query-exec
   connection
   "INSERT INTO pos_schema_migrations (version, name) VALUES (?, ?)"
   (pos-database-migration-version migration)
   (pos-database-migration-name migration)))

(define (migrate-pos-database! connection)
  (unless (db:connection? connection)
    (raise-argument-error
     'migrate-pos-database!
     "connection?"
     connection))

  (db:call-with-transaction
   connection
   (lambda ()
     (db:query-exec connection create-migrations-table-sql)
     (define applied-migrations
       (read-pos-database-migration-history connection))
     (validate-applied-pos-database-schema!
      connection applied-migrations 'migrate-pos-database!)

     (define applied-count (length applied-migrations))
     (for ([migration (in-list (drop migrations applied-count))])
       ((pos-database-migration-apply! migration) connection)
       ((pos-database-migration-validate! migration) connection)
       (record-migration! connection migration)))
   #:option 'immediate)
  (void))
