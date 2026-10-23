# 02.1_model_validation.md — проверка сборки модели SQLite

## Файлы

- `severtrade_model.db` — база SQLite с тремя слоями: `raw_*`, `core_*`, `mart_*`.
- `02.1_model_build.sql` — SQL-скрипт пересоздания производных таблиц `core_*` и `mart_*` из сохранённых таблиц `raw_*`. Исходный слой скрипт не удаляет.

## Результаты проверок

### 1. Целостность файла базы

```sql
PRAGMA integrity_check;
```

**Результат:** `ok`.

```sql
PRAGMA foreign_key_check;
```

**Результат:** 0 строк с нарушениями внешних ключей.

### 2. Сверка количества строк между слоями

```sql
SELECT
  (SELECT COUNT(*) FROM raw_po_lines) =
  (SELECT COUNT(*) FROM core_po_line_version) AS raw_core_line_counts_match,
  (SELECT COUNT(*) FROM raw_receipts) =
  (SELECT COUNT(*) FROM core_fact_receipt) AS raw_core_receipt_counts_match;
```

**Результат:** оба сравнения истинны. В `raw_po_lines` и `core_po_line_version` по 55 644 строки; в `raw_receipts` и `core_fact_receipt` по 63 691 строке.

Полная проверка количества строк:

```sql
SELECT 'raw_po_headers' AS table_name, COUNT(*) AS row_count FROM raw_po_headers
UNION ALL SELECT 'raw_po_lines', COUNT(*) FROM raw_po_lines
UNION ALL SELECT 'raw_receipts', COUNT(*) FROM raw_receipts
UNION ALL SELECT 'raw_suppliers', COUNT(*) FROM raw_suppliers
UNION ALL SELECT 'raw_items', COUNT(*) FROM raw_items
UNION ALL SELECT 'raw_uom', COUNT(*) FROM raw_uom
UNION ALL SELECT 'raw_fx_rates', COUNT(*) FROM raw_fx_rates
UNION ALL SELECT 'core_po_header', COUNT(*) FROM core_po_header
UNION ALL SELECT 'core_po_line_version', COUNT(*) FROM core_po_line_version
UNION ALL SELECT 'core_fact_receipt', COUNT(*) FROM core_fact_receipt
UNION ALL SELECT 'core_supplier_version', COUNT(*) FROM core_supplier_version
UNION ALL SELECT 'core_dim_item', COUNT(*) FROM core_dim_item
UNION ALL SELECT 'core_dim_uom', COUNT(*) FROM core_dim_uom
UNION ALL SELECT 'core_dim_fx_rate', COUNT(*) FROM core_dim_fx_rate
UNION ALL SELECT 'mart_order_line_versions', COUNT(*) FROM mart_order_line_versions
UNION ALL SELECT 'mart_receipts_by_order_line', COUNT(*) FROM mart_receipts_by_order_line
ORDER BY table_name;
```

| Таблица | Строк |
|---|---:|
| `raw_po_headers` | 21 292 |
| `raw_po_lines` | 55 644 |
| `raw_receipts` | 63 691 |
| `raw_suppliers` | 143 |
| `raw_items` | 760 |
| `raw_uom` | 8 |
| `raw_fx_rates` | 1 366 |
| `core_po_header` | 21 292 |
| `core_po_line_version` | 55 644 |
| `core_fact_receipt` | 63 691 |
| `core_supplier_version` | 143 |
| `core_dim_item` | 760 |
| `core_dim_uom` | 8 |
| `core_dim_fx_rate` | 1 366 |
| `mart_order_line_versions` | 55 644 |
| `mart_receipts_by_order_line` | 46 008 |

### 3. Повторяющиеся ключи строк заказа

```sql
SELECT COUNT(*) AS duplicate_order_line_groups
FROM (
  SELECT order_id, line_no
  FROM raw_po_lines
  GROUP BY order_id, line_no
  HAVING COUNT(*) > 1
);
```

**Результат:** 2 375 групп с повторяющейся парой `(order_id, line_no)`. Поэтому `core_po_line_version` хранит технический ключ `line_version_sk` и не устанавливает уникальность на паре бизнес-ключей. Повторяющиеся строки не удаляются автоматически.

### 4. Уникальность идентификатора поступления

```sql
SELECT COUNT(*) AS duplicate_receipt_id_groups
FROM (
  SELECT receipt_id
  FROM raw_receipts
  GROUP BY receipt_id
  HAVING COUNT(*) > 1
);
```

**Результат:** 0 групп с повторяющимся `receipt_id` в этом снимке данных. Это не гарантирует уникальность при будущих загрузках; требуется проверка контракта источника и контроль на каждой загрузке.

### 5. Строки заказа без заголовка

```sql
SELECT COUNT(*) AS unmatched_lines
FROM core_po_line_version l
LEFT JOIN core_po_header h ON h.order_id = l.order_id
WHERE h.order_id IS NULL;
```

**Результат:** 0.

### 6. Поступления без совпадающей строки заказа

```sql
SELECT COUNT(*) AS receipts_without_matching_order_line
FROM core_fact_receipt r
WHERE NOT EXISTS (
  SELECT 1
  FROM core_po_line_version l
  WHERE l.order_id = r.order_id
    AND l.line_no = r.line_no
);
```

**Результат:** 0. Проверка подтверждает наличие хотя бы одной строки с такой бизнес-парой, но не проверяет кардинальность один-к-одному: в заказах сохраняются повторные версии строк.

### 7. Заказы без найденной версии поставщика

```sql
SELECT COUNT(*) AS orders_without_supplier_version
FROM core_po_header h
WHERE NOT EXISTS (
  SELECT 1
  FROM core_supplier_version s
  WHERE s.supplier_id = h.supplier_id
    AND date(h.order_dttm_msk) >= date(s.valid_from)
    AND (s.valid_to IS NULL OR date(h.order_dttm_msk) < date(s.valid_to))
);
```

**Результат:** 233 заказа при условии, что интервал действия версии поставщика трактуется как полуоткрытый: `[valid_from, valid_to)`. Это диагностический результат, а не подтверждённый дефект: владелец данных должен подтвердить семантику `valid_to` и формат дат.

## Принятые решения и ограничения

1. Таблицы `raw_*` сохраняют строки и поля, импортированные из исходных файлов.
2. `core_po_line_version` сохраняет все исходные версии строк заказа. Последняя версия по `updated_at` автоматически не выбирается: смысл поля и переходов статусов ещё не подтверждён.
3. `core_fact_receipt` использует `receipt_id` как первичный ключ, поскольку он уникален в текущем снимке. Для инкрементальной загрузки требуется подтвердить стабильность этого ID по контракту источника.
4. `mart_receipts_by_order_line` агрегирует события поступления до `(order_id, line_no)`, чтобы уменьшить риск умножения значений заказа при соединении.
5. `mart_order_line_versions` содержит все версии строк и признак `version_resolution_status`; это не витрина однозначно выбранного текущего состояния.
6. Исходные цена и валюта сохраняются. Пересчёт в рубли не материализован: правила выбора курса и округления пока не согласованы.
7. История поставщиков сохранена в `core_supplier_version`. Атрибуты поставщика не подставляются в заголовок заказа автоматически без подтверждённого правила исторической привязки.

## Где я мог соврать

1. `receipt_id` уникален только в проверенном снимке. Проверять это нужно при каждой загрузке и подтвердить контрактом Kafka.
2. Полуоткрытый интервал `[valid_from, valid_to)` выбран для диагностической проверки как предположение. После уточнения правила повторить запрос для покрытия поставщиков.
3. Наличие строки с парой `(order_id, line_no)` не означает, что её версия выбрана правильно. До утверждения правил версионирования не считать `mart_order_line_versions` таблицей текущих состояний.
