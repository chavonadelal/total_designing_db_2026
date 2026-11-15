# Обоснование ограничений — FOOD-101

Схема `konov_food`, таблицы — в `schema/01_tables.sql`. `"order"` взята в кавычки (BR-13.1).
ID — UUID с `DEFAULT exts.uuid_generate_v4()` (BR-11.1, BR-13.3).
Даты и время без таймзоны — время сервера (BR-11.2). Деньги — точный numeric с двумя
знаками, количество — с тремя (BR-7.15), рейтинг — с двумя; varchar 20–150 символов
по назначению поля, телефон — 12 символов с `+7` (BR-11.6).

## Enum

| Тип | Значения | BR |
|---|---|---|
| restaurant_status | активен, неактивен | BR-4.3 |
| product_status | доступно, нет_в_наличии, архив | BR-5.5 |
| courier_status | свободен, занят, на_доставке, уволен | BR-6.2 |
| order_status | создан, готовится, в_доставке, доставлен, отменён | BR-7.7 |
| order_pay_status | ожидает, оплачен, ошибка | BR-7.9 |
| payment_status | успех, ошибка, в_обработке | BR-8.2 |
| payment_type | карта, наличные, безнал | BR-8.2, BR-8.6 |
| review_entity_type | блюдо, ресторан, заказ | BR-9.1 |

## CHECK

Непустая строка проверяется через `btrim(...) <> ''`. У цен, сумм и количества
дополнительно исключён NaN, который в PostgreSQL проходит обычное `>= 0`.

| Таблица, поля | Условие | BR и обоснование |
|---|---|---|
| client.login | непустой | BR-2.1, BR-11.3: обязательный логин |
| client.password | 32 hex-символа | BR-2.3: MD5 |
| client.phone_number | +7 и 10 цифр | BR-2.1, BR-11.6: формат телефона |
| address.street, house_number | непустые | BR-3.1, BR-11.3: обязательные части адреса |
| address.apartment_office | NULL либо непустое | BR-3.2: номер необязателен |
| restaurant.restaurant_name, description, company_details | непустые | BR-4.1, BR-4.5, BR-11.3: атрибуты ресторана |
| restaurant.work_end | > work_start | BR-4.4: закрытие позже открытия |
| restaurant.rating | 0–5 | BR-4.2: диапазон рейтинга |
| courier.fio | непустое | BR-6.1, BR-11.3: обязательное ФИО |
| courier.phone_number | +7 и 10 цифр | BR-6.1, BR-11.6: формат телефона |
| courier.coefficient | 0.1–0.5 | BR-6.4: диапазон коэффициента |
| courier.status, dismissal_date | уволен ⇒ дата заполнена | BR-6.3: дата увольнения обязательна |
| courier.dismissal_date | NULL либо >= hire_date | BR-6.1, BR-6.3: согласованность дат |
| courier_pay.year, month | год > 0, месяц 1–12 | BR-10.2–10.3: календарный период |
| courier_pay.amount | >= 0 | BR-10.4: неотрицательная выплата |
| courier_pay.coefficient_used | 0.1–0.5 | BR-6.4, BR-10.2: допустимый применённый коэффициент |
| product_category.product_category_name | непустое | BR-5.7, BR-11.3: название категории |
| product.product_name, description | непустые | BR-5.2, BR-11.3: атрибуты блюда |
| product.price | >= 0 | BR-5.3: неотрицательная цена |
| product.photo_url | NULL либо http(s) URL без пробелов | BR-5.6: ссылка на фото |
| product.rating | 0–5 | BR-5.4: диапазон рейтинга |
| order.order_amount | >= 0 | BR-5.3, BR-7.10: стоимость блюд |
| order.total_amount | >= 1000 | BR-1.8, BR-7.11: минимальная сумма |
| order.description | непустое | ERD, BR-11.3: обязательный атрибут |
| order.status, delivery_timestamp | доставлен ⇒ время заполнено | BR-7.12: время доставки |
| order.delivery_timestamp | NULL либо >= order_timestamp | BR-7.13: доставка не раньше создания |
| order_structure.quantity | > 0 | BR-7.15: положительное дробное количество |
| order_structure.unit_price | >= 0 | BR-5.3, BR-7.10: цена покупки |
| payment.amount | >= 0 | BR-7.11, BR-8.4: неотрицательная сумма |
| payment.transaction_reference | непустое | BR-8.2–8.3: внешний идентификатор |
| review.description | непустое | BR-9.3, BR-11.3: текст отзыва |
| review.photo_url | NULL либо http(s) URL без пробелов | BR-9.3: ссылка на фото |
| review.rating | 1–5 | BR-9.4: диапазон оценки |
| review.entity_type, entity_id, order_id | тип «заказ» ⇒ entity_id = order_id | BR-9.2: отзыв именно на свой заказ |

## UNIQUE и составные PK

| Таблица, поля | BR и обоснование |
|---|---|
| client.login, отдельно client.phone_number | BR-2.2: уникальные логин и телефон |
| address(street, house_number, apartment_office), NULLS NOT DISTINCT | BR-3.1, BR-3.3: одна запись физического адреса, включая отсутствие квартиры |
| restaurant.address_id | BR-3.3: два ресторана не делят адрес |
| client_address PK(client_id, address_id) | BR-2.5: привязка без дублей |
| order_structure PK(order_id, product_id) | BR-7.16: блюдо один раз в заказе |
| courier_pay PK(year, month, courier_id) | BR-10.3: одна выплата в месяц |
| payment.transaction_reference | BR-8.3: уникальная внешняя транзакция |
| payment(order_id) WHERE status = 'успех' | BR-8.1: не более одного успеха |
| review(order_id, entity_type, entity_id) | BR-9.5: один отзыв на объект заказа |
| order(order_id, restaurant_id) | BR-9.2: ключ для FK отзыва на ресторан |
| order(order_id, total_amount) | BR-8.4: ключ для равенства суммы оплаты |

## FK

Используется NO ACTION: адреса и история не удаляются каскадом (BR-3.5).

| Откуда | Куда | BR и обоснование |
|---|---|---|
| client_address.client_id | client.client_id | BR-2.4: существующий клиент |
| client_address.address_id | address.address_id | BR-2.4: существующий адрес |
| restaurant.address_id | address.address_id | BR-3.3: адрес ресторана |
| courier_pay.courier_id | courier.courier_id | BR-10.2: получатель выплаты |
| product.product_category_id | product_category.product_category_id | BR-5.1: категория блюда |
| product.restaurant_id | restaurant.restaurant_id | BR-5.1: ресторан блюда |
| order.courier_id | courier.courier_id | BR-7.5: курьер доставки |
| order.client_id | client.client_id | BR-7.1–7.2: клиент заказа |
| order.address_id | address.address_id | BR-7.4: адрес доставки |
| order.restaurant_id | restaurant.restaurant_id | BR-7.2: ресторан заказа |
| order(client_id, address_id) | client_address(client_id, address_id) | BR-7.4: адрес принадлежит клиенту |
| order_structure.order_id | order.order_id | BR-7.14: заказ позиции |
| order_structure.product_id | product.product_id | BR-7.14: блюдо позиции |
| payment(order_id, amount) | order(order_id, total_amount) | BR-8.4: существующий заказ и равная сумма |
| review.order_id | order.order_id | BR-9.2: заказ и через него автор отзыва |
| review(order_id, product_id) | order_structure(order_id, product_id) | BR-9.2: купленное блюдо |
| review(order_id, restaurant_id) | order(order_id, restaurant_id) | BR-9.2: ресторан своего заказа |

## NOT NULL, NULL и DEFAULT

Остальные поля обязательны по BR-11.3 и правилам соответствующих сущностей;
у таблиц связей обязательность обеспечена PK. Допустимые NULL:

| Поля | Обоснование |
|---|---|
| address.apartment_office | BR-3.2: номер может отсутствовать |
| product.photo_url, review.photo_url | BR-5.6, BR-9.3: фото необязательно |
| courier.dismissal_date | BR-6.3: работающий курьер |
| order.delivery_timestamp | BR-7.12: ещё не доставлен |
| product.rating, restaurant.rating | BR-9.7: нет отзывов |
| review.product_id, restaurant_id | вычисляемые FK, заполненные согласно entity_type |

DEFAULT: UUID для самостоятельных ID (BR-11.1), коэффициент 0.1 (BR-6.5),
localtimestamp для времени заказа, платежа и отзыва (BR-7.1, BR-8.2, BR-9.3).

## Нормализация и межстрочные правила

- Сущности и справочники разделены. Атрибуты зависят от полного PK, самостоятельных
  транзитивных зависимостей нет (3НФ). Автор отзыва определяется через `order.client_id`;
  `review.client_id` исключён как транзитивно зависимый атрибут (BR-7.1, BR-9.2).
- `commission` и `total_amount` вычисляются через GENERATED по BR-1.4, BR-7.10.
  Рейтинги — управляемая денормализация для чтения, поддерживаются `rating_change`
  при INSERT/UPDATE/DELETE, включая смену адресата и отсутствие отзывов (BR-9.6–9.7).
- Полиморфный `review.entity_id` проверяется вычисляемыми `product_id`/`restaurant_id`
  и составными FK; для отзыва на заказ — CHECK (BR-9.1–9.2).
- `check_order_contents` проверяет при COMMIT непустой состав, один ресторан и сумму
  позиций (BR-7.3, BR-7.10, BR-7.14). `unit_price` фиксирует цену покупки;
  `set_order_price` по умолчанию копирует цену меню, сохраняя историю (BR-7.10).
- `payment` дополнена type, amount, transaction_reference, transaction_timestamp, status
  по BR-8.2. Тип оплаты хранится у попытки (BR-8.6), pay_status поддерживается триггером (BR-8.7).
  До успешной оплаты допустимы ожидание и ошибки; второй успех запрещён (BR-8.1, BR-8.7).
- Повторный `insert_test_data(n)` добавляет данные. Генератор сам рассчитывает рейтинги,
  выплаты, цены и статусы, без прямых вызовов собственных функций/процедур (FOOD-102).
- Месяц отчётов и зарплат — по order_timestamp, как в C.8 шаблона тестов.
  coefficient_used хранит коэффициент месяца; courier.coefficient после расчёта — следующий.
  Повторная зарплата использует сохранённый coefficient_used (BR-10.2, FOOD-102, FOOD-107).
