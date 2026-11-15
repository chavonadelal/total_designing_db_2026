SET search_path TO konov_food, exts;

-- FOOD-102. Каждое выполнение добавляет независимую порцию связанных данных.
CREATE PROCEDURE insert_test_data(value integer)
LANGUAGE plpgsql SET search_path = konov_food, pg_temp AS $$
DECLARE
    v_batch text := exts.uuid_generate_v4()::text;
    v_addresses uuid[] := '{}';
    v_clients uuid[] := '{}';
    v_couriers uuid[] := '{}';
    v_categories uuid[] := '{}';
    v_restaurants uuid[] := '{}';
    v_products uuid[] := '{}';
    v_prices numeric[] := '{}';
    v_line_products uuid[];
    v_line_prices numeric[];
    v_quantities numeric[];
    v_id uuid;
    v_client uuid;
    v_order uuid;
    v_entity uuid;
    v_phone varchar(12);
    v_price numeric;
    v_amount numeric;
    v_total numeric;
    v_quantity numeric;
    v_first_month timestamp := date_trunc('month', localtimestamp) - interval '5 months';
    v_month timestamp;
    v_created timestamp;
    v_delivered timestamp;
    v_status order_status;
    v_courier_status courier_status;
    v_entity_type review_entity_type;
    v_restaurant_statuses restaurant_status[] := enum_range(NULL::restaurant_status);
    v_product_statuses product_status[] := enum_range(NULL::product_status);
    v_courier_statuses courier_status[] := enum_range(NULL::courier_status);
    v_order_statuses order_status[] := enum_range(NULL::order_status);
    v_order_pay_statuses order_pay_status[] := enum_range(NULL::order_pay_status);
    v_payment_statuses payment_status[] := enum_range(NULL::payment_status);
    v_payment_types payment_type[] := enum_range(NULL::payment_type);
    v_entity_types review_entity_type[] := enum_range(NULL::review_entity_type);
    v_index integer;
    v_count integer;
    v_offset integer;
    i integer;
    j integer;
    k integer;
BEGIN
    IF value IS NULL OR value <= 0 THEN
        RAISE invalid_parameter_value USING MESSAGE = 'value должен быть положительным целым числом';
    END IF;

    FOR i IN 1..value * 5 LOOP
        INSERT INTO address (street, house_number, apartment_office)
        VALUES ('Улица ' || v_batch || '-' || i, (1 + i % 50)::text,
                CASE WHEN i % 4 = 0 THEN NULL ELSE (1 + i % 100)::text END)
        RETURNING address_id INTO v_id;
        v_addresses := array_append(v_addresses, v_id);
    END LOOP;

    FOR i IN 1..value LOOP
        LOOP
            v_phone := '+7' || (9000000000 + floor(random() * 1000000000)::bigint)::text;
            EXIT WHEN NOT EXISTS (SELECT 1 FROM client WHERE phone_number = v_phone);
        END LOOP;
        INSERT INTO client (login, password, phone_number)
        VALUES ('client_' || v_batch || '_' || i, md5(random()::text), v_phone)
        RETURNING client_id INTO v_id;
        v_clients := array_append(v_clients, v_id);

        -- У первого курьера гарантированно рабочий статус.
        v_courier_status := v_courier_statuses[1 + floor(random() * cardinality(v_courier_statuses))::int];
        IF i = 1 THEN v_courier_status := v_courier_statuses[1]; END IF;
        INSERT INTO courier (fio, phone_number, status, hire_date, dismissal_date)
        VALUES ('Курьер ' || i || ' ' || left(v_batch, 8), v_phone, v_courier_status,
                v_first_month::date,
                CASE WHEN v_courier_status = 'уволен' THEN current_date END)
        RETURNING courier_id INTO v_id;
        v_couriers := array_append(v_couriers, v_id);

        INSERT INTO product_category (product_category_name)
        VALUES ('Категория ' || i || ' ' || left(v_batch, 8))
        RETURNING product_category_id INTO v_id;
        v_categories := array_append(v_categories, v_id);

        INSERT INTO restaurant (restaurant_name, address_id, description, work_start, work_end,
                                company_details, status)
        VALUES ('Ресторан ' || i || ' ' || left(v_batch, 8), v_addresses[i],
                'Описание ресторана ' || i, time '08:00' + random() * interval '3 hours',
                time '18:00' + random() * interval '4 hours', 'Тестовые реквизиты ' || v_batch || '-' || i,
                v_restaurant_statuses[1 + floor(random() * cardinality(v_restaurant_statuses))::int])
        RETURNING restaurant_id INTO v_id;
        v_restaurants := array_append(v_restaurants, v_id);

        -- Остальные 4 * value адресов принадлежат клиентам, по четыре каждому.
        FOR j IN 1..4 LOOP
            INSERT INTO client_address (client_id, address_id)
            VALUES (v_clients[i], v_addresses[value + (i - 1) * 4 + j]);
        END LOOP;
    END LOOP;

    FOR i IN 1..value LOOP
        FOR j IN 1..5 LOOP
            v_price := round((1000 + random() * 2000)::numeric, 2);
            INSERT INTO product (product_name, product_category_id, price, restaurant_id,
                                 photo_url, status, description)
            VALUES ('Блюдо ' || i || '-' || j || ' ' || left(v_batch, 8),
                    v_categories[1 + floor(random() * value)::int], v_price, v_restaurants[i],
                    CASE WHEN j % 2 = 0 THEN 'https://example.org/food/' || v_batch || '/' || i || '-' || j || '.jpg' END,
                    v_product_statuses[1 + floor(random() * cardinality(v_product_statuses))::int],
                    'Описание блюда ' || j)
            RETURNING product_id INTO v_id;
            v_products := array_append(v_products, v_id);
            v_prices := array_append(v_prices, v_price);
        END LOOP;
    END LOOP;

    FOR i IN 1..value LOOP
        FOR j IN 1..5 LOOP
            v_index := 1 + floor(random() * value)::int;
            v_client := v_clients[v_index];
            v_count := 1 + floor(random() * 5)::int;
            v_offset := floor(random() * 5)::int;
            v_line_products := '{}';
            v_line_prices := '{}';
            v_quantities := '{}';
            v_amount := 0;
            FOR k IN 1..v_count LOOP
                -- Циклический сдвиг даёт разные блюда одного ресторана без повторов.
                v_index := (i - 1) * 5 + 1 + (v_offset + k - 1) % 5;
                v_quantity := 1 + floor(random() * 6)::numeric / 2;
                v_line_products := array_append(v_line_products, v_products[v_index]);
                v_line_prices := array_append(v_line_prices, v_prices[v_index]);
                v_quantities := array_append(v_quantities, v_quantity);
                v_amount := v_amount + round(v_prices[v_index] * v_quantity, 2);
            END LOOP;
            v_month := v_first_month + (((i - 1) * 5 + j - 1) % 6) * interval '1 month';
            v_created := v_month + random() * (least(v_month + interval '1 month', localtimestamp) - v_month);
            v_status := v_order_statuses[1 + floor(random() * cardinality(v_order_statuses))::int];
            IF j = 1 THEN v_status := v_order_statuses[4]; END IF;
            v_delivered := CASE WHEN v_status = 'доставлен'
                THEN least(v_created + interval '30 minutes', localtimestamp) END;

            INSERT INTO "order" (courier_id, client_id, address_id, restaurant_id,
                                 order_timestamp, delivery_timestamp, order_amount, status, pay_status, description)
            VALUES (v_couriers[1 + floor(random() * value)::int], v_client,
                    -- Первый из четырёх адресов выбранного клиента.
                    v_addresses[value + (array_position(v_clients, v_client) - 1) * 4 + 1],
                    v_restaurants[i], v_created, v_delivered, v_amount, v_status, v_order_pay_statuses[2], 'Тестовый заказ')
            RETURNING order_id, total_amount INTO v_order, v_total;

            FOR k IN 1..v_count LOOP
                INSERT INTO order_structure (order_id, product_id, quantity, unit_price)
                VALUES (v_order, v_line_products[k], v_quantities[k], v_line_prices[k]);
            END LOOP;
            -- 5 * value платежей на 5 * value заказов: одна успешная попытка на заказ.
            INSERT INTO payment (order_id, type, amount, transaction_reference, transaction_timestamp, status)
            VALUES (v_order, v_payment_types[1 + floor(random() * cardinality(v_payment_types))::int],
                    v_total, 'txn_' || v_order, v_created, v_payment_statuses[1]);

            v_entity_type := v_entity_types[1 + floor(random() * cardinality(v_entity_types))::int];
            v_entity := CASE v_entity_type
                WHEN 'блюдо' THEN v_line_products[1 + floor(random() * v_count)::int]
                WHEN 'ресторан' THEN v_restaurants[i] ELSE v_order END;
            INSERT INTO review (order_id, review_timestamp, entity_id, entity_type, description, photo_url, rating)
            VALUES (v_order, least(v_created + interval '1 hour', localtimestamp), v_entity, v_entity_type,
                    'Отзыв на тестовый заказ',
                    CASE WHEN j % 2 = 0 THEN 'https://example.org/review/' || v_order || '.jpg' END,
                    1 + floor(random() * 5)::int);
        END LOOP;
    END LOOP;

    -- Прямой расчёт: результат генератора не зависит от вызова rating_change().
    UPDATE product p SET rating = a.rating
    FROM (
        SELECT entity_id, round(avg(rating), 2) AS rating
        FROM review WHERE entity_type = 'блюдо' AND entity_id = ANY(v_products)
        GROUP BY entity_id
    ) a WHERE p.product_id = a.entity_id;
    UPDATE restaurant r SET rating = a.rating
    FROM (
        SELECT entity_id, round(avg(rating), 2) AS rating
        FROM review WHERE entity_type = 'ресторан' AND entity_id = ANY(v_restaurants)
        GROUP BY entity_id
    ) a WHERE r.restaurant_id = a.entity_id;

    -- Выплаты создаются напрямую, без вызова courier_salary().
    FOR k IN 0..5 LOOP
        v_month := v_first_month + k * interval '1 month';
        INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
        SELECT extract(year FROM v_month)::int, extract(month FROM v_month)::int,
               c.courier_id, round(c.coefficient * coalesce(sum(o.commission), 0), 2), c.coefficient
        FROM courier c LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
            AND o.order_timestamp >= v_month AND o.order_timestamp < v_month + interval '1 month'
        WHERE c.courier_id = ANY(v_couriers)
        GROUP BY c.courier_id;

        WITH deliveries AS (
            SELECT c.courier_id, count(o.order_id) AS n
            FROM courier c LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
                AND o.order_timestamp >= v_month AND o.order_timestamp < v_month + interval '1 month'
            WHERE c.courier_id = ANY(v_couriers) AND c.status <> 'уволен'
            GROUP BY c.courier_id
        )
        UPDATE courier c SET coefficient = CASE
            WHEN d.n <= 150 THEN 0.1 WHEN d.n <= 250 THEN 0.2
            WHEN d.n <= 500 THEN 0.3 ELSE 0.5 END
        FROM deliveries d WHERE c.courier_id = d.courier_id;
    END LOOP;
END;
$$;

-- FOOD-103. Все связанные таблицы указаны явно; объекты схемы сохраняются.
CREATE PROCEDURE erase_test_data()
LANGUAGE plpgsql SET search_path = konov_food, pg_temp AS $$
BEGIN
    TRUNCATE TABLE review, payment, order_structure, "order", courier_pay,
                   client_address, product, restaurant, product_category, courier, client, address;
END;
$$;
