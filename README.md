# База данных FoodExpress

Работа Конова. Схема `konov_food`, проверено на PostgreSQL 16.15.

Состав решения: [SQL-скрипты](db/schema/), [обоснования](db/constraints.md),
[протокол проверки](db/tests.md), `db/foodexpress_konov.backup`.
Условия задания сохранены в `docs/`.

## Восстановление

Целевая БД `foodexpress` должна быть пустой, с подготовленной схемой `exts`
и расширением `uuid-ossp`. Под администратором:

```sh
pg_restore -U postgres -d foodexpress --no-owner --no-acl --exit-on-error db/foodexpress_konov.backup
psql -U postgres -d foodexpress -v ON_ERROR_STOP=1 -f db/schema/grants.sql
```

## Проверка

Подключение — `psql -U inspector -d foodexpress`, пароль `NetoSQL2025`.

```sql
SET search_path TO konov_food, exts;
CALL erase_test_data();
CALL insert_test_data(10);
SELECT * FROM get_statistic();
CALL courier_salary();
SELECT * FROM how_much_money ORDER BY year_month;
```
