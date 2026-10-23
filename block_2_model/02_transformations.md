# 02.5_transformations.md — Правила трансформации

## Статусы правил

- **Реализовано в прототипе:** преобразование выполняется в SQLite-сборке.
- **Предложение:** правило для целевой модели, требует согласования.
- **Блокирующее допущение:** нельзя публиковать официальный KPI до подтверждения.

## Источник → raw → core → mart

1. CSV читаются с разделителем `;` и UTF-8. Raw-слой хранит загруженные поля и строки. В промышленной загрузке дополнить `batch_id`, `loaded_at`, именем файла, checksum, количеством строк и статусом загрузки.
2. Core типизирует поля и сохраняет естественные ключи. Для строк заказа сохранять lineage `source_row_no`; не удалять строки только потому, что `(order_id, line_no)` повторяется.
3. Приёмки хранить как события; агрегировать по `(order_id, line_no)` в отдельной витрине, чтобы не умножать суммы при соединениях.
4. Справочники сохранять как отдельные сущности; unknown keys должны быть наблюдаемыми, а не теряться из-за `INNER JOIN`.

## Версионирование строки заказа

- Наблюдаемая строка — версия источника, а не обязательно каноническое состояние.
- `updated_at` сохраняется и индексируется, но нельзя выбрать `ROW_NUMBER() ORDER BY updated_at DESC` как официальный алгоритм без подтверждения, что это время изменения и что поздняя запись побеждает.
- До подтверждения строить диагностическую группу по `(order_id, line_no)`, выставлять `version_resolution_status`, хранить все версии.
- После подтверждения: документировать статусы отмены, tie-breaker, допустимость одинакового `updated_at`, и возможность физического удаления строки.
- Пример диагностики:

```sql
SELECT order_id, line_no, COUNT(*) AS observed_versions,
       MIN(updated_at) AS first_seen_updated_at,
       MAX(updated_at) AS last_seen_updated_at
FROM core_po_line_version
GROUP BY order_id, line_no
HAVING COUNT(*) > 1;
```

## История поставщика

Предложение: SCD Type 2 с полуоткрытым интервалом `[valid_from, valid_to)`. Это не считать утверждённым до подтверждения источником. Не использовать `is_current=1` для исторического заказа.

```sql
SELECT h.order_id, h.supplier_id, h.order_dttm_msk,
       COUNT(s.supplier_version_sk) AS matching_supplier_versions
FROM core_po_header h
LEFT JOIN core_supplier_version s
  ON s.supplier_id = h.supplier_id
 AND date(h.order_dttm_msk) >= date(s.valid_from)
 AND (s.valid_to IS NULL OR date(h.order_dttm_msk) < date(s.valid_to))
GROUP BY h.order_id, h.supplier_id, h.order_dttm_msk
HAVING COUNT(s.supplier_version_sk) <> 1;
```

## Приёмки и идемпотентность

- Текущая выгрузка имеет `receipt_id`; пример API отдельно показывает `event_id`. Не переименовывать и не считать их эквивалентными без контракта.
- Если `receipt_id` подтверждён как глобально уникальный и неизменный идентификатор события, использовать его для upsert. Иначе запросить у WMS стабильный event ID.
- Конфликт одинакового ID с разным payload — quarantine + алерт; одинаковый ID и payload — повторная доставка, не создавать второе событие.
- Out-of-order не исправлять порядком прихода сообщения; опираться на event timestamp и правила корректировки/компенсации.
- Агрегат приёмок строить отдельно от версий строк заказа.

## Валюта

- Сохранять исходную сумму/цену и код валюты.
- Курс соединять по утверждённой дате и валюте; точный матч по дате — только стартовая диагностическая проверка.
- Не подменять отсутствующий курс курсом предыдущего дня без утверждённой политики.
- Для production использовать `NUMERIC/DECIMAL`, определить округление и правила НДС/скидок.

## Единицы измерения

- `qty_base = qty × factor_to_base`.
- Для цены за базовую единицу: `price_base = price / factor_to_base` только если коэффициент означает «сколько базовых единиц в одной исходной единице». Семантику коэффициента подтвердить на справочнике.
- Если коэффициент отсутствует/неположителен или ЕИ несовместимы — не сравнивать цены; выдавать DQ-флаг.
- Не смешивать цену упаковки с ценой штуки до проверки направления коэффициента.

## Номенклатура без справочника

- Не терять строку при enrichment; `item_id` сохраняется, `item_name/category` остаются NULL/unknown.
- Не сопоставлять автоматически по похожему тексту в рамках пилота.
- Выводить отдельный показатель покрытия справочником и список на разбор владельцу НСИ.

## Проверки после загрузки

```sql
PRAGMA integrity_check;
PRAGMA foreign_key_check;

SELECT COUNT(*) FROM raw_po_lines;
SELECT COUNT(*) FROM core_po_line_version;
SELECT COUNT(*) FROM mart_order_line_versions;

SELECT COUNT(*) FROM raw_receipts;
SELECT COUNT(*) FROM core_fact_receipt;

SELECT COUNT(*) FROM (
  SELECT order_id, line_no
  FROM core_po_line_version
  GROUP BY order_id, line_no
  HAVING COUNT(*) > 1
);
```

Для PostgreSQL заменить `PRAGMA` на проверки constraints и контрольные запросы row-count/reconciliation. Результат проверки должен логироваться с batch ID.
