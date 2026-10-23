# Дефекты и проверки качества данных (Блок 2)

В этом документе числовые утверждения сопровождаются SQL, которым их можно перепроверить в `severtrade_model.db`. Значения относятся к текущему снимку базы; они не доказывают первопричину дефекта.

## Сводка фактических проверок

| Проверка | Результат | Интерпретация / обработка |
|---|---:|---|
| Группы повторяющихся ключей `(order_id, line_no)` в сырых строках заказа | 2375 | Вероятные версии/повторные строки; не удалять без правила версионирования. |
| Повторяющиеся `receipt_id` | 0 | В текущем снимке дублей по `receipt_id` не найдено; стабильность ключа между переигровками не доказана. |
| Строки заказа без шапки | 0 | Проверка ссылочной целостности core; в текущей модели не обнаружены. |
| События приёмки без пары заказа/строки | 0 | Проверка связи по `(order_id, line_no)`; в текущем снимке не обнаружены. |
| Шапки без версии поставщика, попадающей в интервал на дату заказа | 233 | Возможен пробел истории, несовпадение ключей или иная семантика `valid_to`; не подставлять текущую версию автоматически. |
| Группы строк с несколькими версиями | 2375 | Требуют определения канонической версии для KPI; сохранять историю и показывать статус разрешения. |
| Строки без `item_id` | 0 | Номенклатура не идентифицирована; отдельная категория «не сопоставлено», не терять из сверки. |
| Ненайденный `item_id` в справочнике | 2846 | Требует quarantine/unknown-member и DQ алерта. |
| Валютные строки без курса на дату заказа (кроме RUB/RUR) | 647 | Проверка по точной дате; если утверждён другой курс-день — пересчитать по бизнес-правилу. |
| ЕИ без положительного коэффициента пересчёта | 0 | Сравнение цены за базовую ЕИ запрещено до исправления коэффициента. |
| Строки без плановой даты поставки | 0 | Нельзя честно оценить on-time/OTIF; исключать из знаменателя только по утверждённому правилу и показывать coverage. |
| Строки без статуса | 0 | Нельзя безопасно исключить отмены; статусная классификация требует уточнения. |

## SQL для воспроизводимости

```sql
-- Повторяющиеся ключи строк заказа
SELECT COUNT(*) AS duplicate_key_groups
FROM (
  SELECT order_id, line_no
  FROM raw_po_lines
  GROUP BY order_id, line_no
  HAVING COUNT(*) > 1
);

-- Дубли идентификатора приёмки в текущем снимке
SELECT COUNT(*) AS duplicate_receipt_id_groups
FROM (
  SELECT receipt_id
  FROM raw_receipts
  GROUP BY receipt_id
  HAVING COUNT(*) > 1
);

-- Строки без шапки
SELECT COUNT(*) AS orphan_line_versions
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

-- Поставщик не сопоставился по предполагаемому интервалу [valid_from, valid_to)
SELECT COUNT(*) AS unmatched_supplier_headers
FROM core_po_header h
LEFT JOIN core_supplier_version s
  ON s.supplier_id = h.supplier_id
 AND date(h.order_dttm_msk) >= date(s.valid_from)
 AND (s.valid_to IS NULL OR date(h.order_dttm_msk) < date(s.valid_to))
WHERE s.supplier_id IS NULL;

-- Группы с несколькими наблюдаемыми версиями строки
SELECT COUNT(*) AS multi_version_groups
FROM (
  SELECT order_id, line_no
  FROM core_po_line_version
  GROUP BY order_id, line_no
  HAVING COUNT(*) > 1
);

-- Номенклатура без ссылки на справочник
SELECT COUNT(*) AS unknown_item_references
FROM core_po_line_version l
LEFT JOIN core_dim_item i ON i.item_id = l.item_id
WHERE l.item_id IS NOT NULL AND i.item_id IS NULL;

-- Неизвестные коэффициенты ЕИ
SELECT uom_code, uom_name, base_uom, factor_to_base
FROM core_dim_uom
WHERE factor_to_base IS NULL OR factor_to_base <= 0;

-- Нет курса на точную дату заказа для не-рублёвых валют
SELECT COUNT(*) AS non_rub_lines_without_exact_date_rate
FROM core_po_line_version l
JOIN core_po_header h ON h.order_id = l.order_id
LEFT JOIN core_dim_fx_rate f
  ON f.rate_date = date(h.order_dttm_msk) AND f.currency = h.currency
WHERE h.currency IS NOT NULL
  AND upper(h.currency) NOT IN ('RUB', 'RUR')
  AND f.currency IS NULL;

-- Пропуски плановой даты и статуса
SELECT
  SUM(CASE WHEN planned_delivery_date IS NULL OR trim(planned_delivery_date) = '' THEN 1 ELSE 0 END) AS missing_planned_date,
  SUM(CASE WHEN status IS NULL OR trim(status) = '' THEN 1 ELSE 0 END) AS missing_status
FROM core_po_line_version;
```

## Как дефект влияет на дашборд и что делать

1. **Повторяющиеся `(order_id, line_no)`** → при прямом соединении с приёмками возможен fanout и завышение количества/оборота. Сохранять все версии; строить отдельную таблицу разрешения версии после подтверждения семантики `updated_at` и статусов.
2. **Неоднозначная история поставщика** → исторический класс надёжности и сегмент рейтинга могут быть неверными. Использовать as-of join с интервалом; неоднозначные/несопоставленные случаи помещать в DQ-отчёт.
3. **Отсутствующая номенклатура** → ценовые аномалии и срезы по категориям теряют строки или смешивают несопоставимые позиции. Оставлять unknown bucket, не соединять по названию без отдельного утверждённого matching-процесса.
4. **Отсутствующая/неверная конверсия ЕИ** → цены за штуку/кг/упаковку становятся несопоставимыми. Блокировать расчёт comparable price для строки; показывать coverage и очередь на исправление справочника.
5. **Нет курса на выбранную дату** → сумма в рублях может быть нулевой/искажённой либо строка пропадёт из результата. Не подставлять курс предыдущего дня молча; применить согласованное правило выбора курса, логировать источник и дату курса.
6. **Пустая плановая дата** → строка не может быть классифицирована как on-time; исключение без показа coverage завысит OTIF. Выделять `not_evaluable` и публиковать долю оцениваемых строк.
7. **Нет статуса** → отменённая строка может попасть в знаменатель, или действующая — быть исключена. Ввести mapping статусов с владельцем и версионированием справочника.
8. **UTC и локальное время МСК** → событие около полуночи может попасть в неверный день/период. Нормализовать timestamp в `timestamptz`, хранить исходное значение и явно задавать timezone для отчётных границ.
9. **Деньги в `REAL`/float в прототипе SQLite** → возможны эффекты двоичного округления. В целевом PostgreSQL использовать `numeric`, определить округление и сверять итоги с финансовым источником.

## Ограничения доказательств

- Совпадение `receipt_id` в текущем снимке не подтверждает идемпотентность при повторной доставке; нужен контракт Kafka/WMS.
- Интервал `[valid_from, valid_to)` — рабочее допущение, не подтверждённое владельцем 1С.
- Отсутствие точного курса на дату не доказывает отсутствие курса, который можно использовать по иной утверждённой методике.
- Число повторяющихся групп не равно числу ошибочных строк: это группы для анализа, а не автоматическое основание на удаление.
