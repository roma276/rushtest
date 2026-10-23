-- Выполнить после импорта в PostgreSQL.
-- Проверки количества строк и ссылочной целостности на уровне данных.
SELECT 'core_po_header' AS table_name, COUNT(*) AS row_count FROM core_po_header
UNION ALL SELECT 'core_po_line_version', COUNT(*) FROM core_po_line_version
UNION ALL SELECT 'core_fact_receipt', COUNT(*) FROM core_fact_receipt
UNION ALL SELECT 'core_supplier_version', COUNT(*) FROM core_supplier_version
UNION ALL SELECT 'core_dim_item', COUNT(*) FROM core_dim_item
UNION ALL SELECT 'core_dim_uom', COUNT(*) FROM core_dim_uom
UNION ALL SELECT 'core_dim_fx_rate', COUNT(*) FROM core_dim_fx_rate
UNION ALL SELECT 'mart_order_line_versions', COUNT(*) FROM mart_order_line_versions
UNION ALL SELECT 'mart_receipts_by_order_line', COUNT(*) FROM mart_receipts_by_order_line
ORDER BY table_name;

-- Строки без шапки заказа
SELECT COUNT(*) AS lines_without_header
FROM core_po_line_version l
LEFT JOIN core_po_header h ON h.order_id = l.order_id
WHERE h.order_id IS NULL;

-- Приёмки без пары заказа/строки
SELECT COUNT(*) AS receipts_without_line_pair
FROM core_fact_receipt r
LEFT JOIN (
  SELECT DISTINCT order_id, line_no FROM core_po_line_version
) l ON l.order_id = r.order_id AND l.line_no = r.line_no
WHERE l.order_id IS NULL;

-- Проверка наличия ключевых индексов
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE schemaname='public'
  AND tablename IN ('core_po_line_version','core_fact_receipt','core_supplier_version','core_dim_fx_rate')
ORDER BY tablename,indexname;
