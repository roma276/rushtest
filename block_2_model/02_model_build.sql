-- Build core and marts from raw_* tables in severtrade_model.sqlite
-- Re-runnable: drops only derived layers; raw_* tables remain untouched.
PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS mart_order_line_versions;
DROP TABLE IF EXISTS mart_receipts_by_order_line;
DROP TABLE IF EXISTS core_fact_receipt;
DROP TABLE IF EXISTS core_po_line_version;
DROP TABLE IF EXISTS core_po_header;
DROP TABLE IF EXISTS core_supplier_version;
DROP TABLE IF EXISTS core_dim_item;
DROP TABLE IF EXISTS core_dim_uom;
DROP TABLE IF EXISTS core_dim_fx_rate;

CREATE TABLE core_po_header (
  order_id TEXT PRIMARY KEY,
  supplier_id TEXT,
  order_dttm_msk TEXT,
  currency TEXT,
  delivery_city TEXT,
  order_type TEXT
);
INSERT INTO core_po_header
SELECT order_id, supplier_id, order_dttm_msk, currency, delivery_city, order_type
FROM raw_po_headers;

CREATE TABLE core_po_line_version (
  line_version_sk INTEGER PRIMARY KEY,
  source_row_no INTEGER NOT NULL UNIQUE,
  order_id TEXT NOT NULL,
  line_no TEXT NOT NULL,
  item_id TEXT,
  qty REAL,
  price REAL,
  plan_price REAL,
  uom_code TEXT,
  planned_delivery_date TEXT,
  status TEXT,
  updated_at TEXT,
  FOREIGN KEY (order_id) REFERENCES core_po_header(order_id)
);
INSERT INTO core_po_line_version
  (source_row_no, order_id, line_no, item_id, qty, price, plan_price, uom_code,
   planned_delivery_date, status, updated_at)
SELECT ROW_NUMBER() OVER (ORDER BY rowid), order_id, line_no, item_id, qty, price,
       plan_price, uom_code, planned_delivery_date, status, updated_at
FROM raw_po_lines;
CREATE INDEX ix_core_line_business_key ON core_po_line_version(order_id, line_no);
CREATE INDEX ix_core_line_updated ON core_po_line_version(order_id, line_no, updated_at);

CREATE TABLE core_fact_receipt (
  receipt_id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  line_no TEXT NOT NULL,
  received_at_utc TEXT,
  qty_received REAL,
  quality_status TEXT,
  warehouse_code TEXT
);
INSERT INTO core_fact_receipt
SELECT receipt_id, order_id, line_no, received_at_utc, qty_received, quality_status, warehouse_code
FROM raw_receipts;
CREATE INDEX ix_receipt_order_line_time
  ON core_fact_receipt(order_id, line_no, received_at_utc);

CREATE TABLE core_supplier_version (
  supplier_version_sk INTEGER PRIMARY KEY,
  supplier_id TEXT NOT NULL,
  inn TEXT,
  supplier_name TEXT,
  region TEXT,
  reliability_class TEXT,
  valid_from TEXT,
  valid_to TEXT,
  is_current INTEGER CHECK (is_current IN (0,1) OR is_current IS NULL)
);
INSERT INTO core_supplier_version
  (supplier_version_sk, supplier_id, inn, supplier_name, region, reliability_class,
   valid_from, valid_to, is_current)
SELECT ROW_NUMBER() OVER (ORDER BY rowid), supplier_id, inn, supplier_name, region,
       reliability_class, valid_from, valid_to, is_current
FROM raw_suppliers;
CREATE INDEX ix_supplier_version_validity
  ON core_supplier_version(supplier_id, valid_from, valid_to);

CREATE TABLE core_dim_item (
  item_id TEXT PRIMARY KEY,
  item_name TEXT,
  category TEXT,
  category_reported TEXT,
  uom_code TEXT
);
INSERT INTO core_dim_item SELECT item_id, item_name, category, category_reported, uom_code FROM raw_items;

CREATE TABLE core_dim_uom (
  uom_code TEXT PRIMARY KEY,
  uom_name TEXT,
  base_uom TEXT,
  factor_to_base REAL CHECK (factor_to_base IS NULL OR factor_to_base > 0)
);
INSERT INTO core_dim_uom SELECT uom_code, uom_name, base_uom, factor_to_base FROM raw_uom;

CREATE TABLE core_dim_fx_rate (
  rate_date TEXT NOT NULL,
  currency TEXT NOT NULL,
  rate_to_rub REAL CHECK (rate_to_rub IS NULL OR rate_to_rub > 0),
  PRIMARY KEY (rate_date, currency)
);
INSERT INTO core_dim_fx_rate SELECT rate_date, currency, rate_to_rub FROM raw_fx_rates;

-- Aggregate receipts before joining to order-line versions to prevent row multiplication.
CREATE TABLE mart_receipts_by_order_line AS
SELECT order_id, line_no, COUNT(*) AS receipt_event_count,
       SUM(COALESCE(qty_received, 0)) AS qty_received_total,
       MIN(received_at_utc) AS first_received_at_utc,
       MAX(received_at_utc) AS last_received_at_utc
FROM core_fact_receipt
GROUP BY order_id, line_no;
CREATE UNIQUE INDEX ux_mart_receipts_order_line
  ON mart_receipts_by_order_line(order_id, line_no);

-- No automatic "latest version" resolution: all source versions remain visible.
CREATE TABLE mart_order_line_versions AS
SELECT l.line_version_sk, l.source_row_no, l.order_id, l.line_no, l.item_id,
       i.item_name, i.category, l.qty AS ordered_qty, l.price AS unit_price,
       h.currency, l.plan_price, l.uom_code, u.base_uom, u.factor_to_base,
       l.planned_delivery_date, l.status, l.updated_at,
       CASE WHEN COUNT(*) OVER (PARTITION BY l.order_id, l.line_no) > 1
            THEN 'MULTIPLE_VERSIONS_REVIEW' ELSE 'SINGLE_VERSION' END AS version_resolution_status
FROM core_po_line_version l
LEFT JOIN core_dim_item i ON i.item_id=l.item_id
LEFT JOIN core_dim_uom u ON u.uom_code=l.uom_code
LEFT JOIN core_po_header h ON h.order_id=l.order_id;
CREATE INDEX ix_mart_order_line_order ON mart_order_line_versions(order_id, line_no);
