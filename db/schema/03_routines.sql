SET search_path TO konov_food, exts;

-- FOOD-104. Порядок обязательных аргументов соответствует шаблону проверки.
CREATE PROCEDURE add_product(
    p_restaurant_id uuid,
    p_product_category_id uuid,
    p_name varchar,
    p_price numeric,
    p_rating numeric,
    p_status product_status,
    p_description text,
    p_photo_url text DEFAULT NULL
)
LANGUAGE plpgsql SET search_path = konov_food, pg_temp AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM restaurant WHERE restaurant_id = p_restaurant_id) THEN
        RAISE foreign_key_violation USING MESSAGE = 'Ресторан не существует';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM product_category WHERE product_category_id = p_product_category_id) THEN
        RAISE foreign_key_violation USING MESSAGE = 'Категория блюда не существует';
    END IF;
    IF p_price < 0 THEN
        RAISE check_violation USING MESSAGE = 'Цена блюда не может быть отрицательной';
    END IF;
    IF p_rating NOT BETWEEN 0 AND 5 THEN
        RAISE check_violation USING MESSAGE = 'Рейтинг блюда должен быть от 0 до 5';
    END IF;
    INSERT INTO product (restaurant_id, product_category_id, product_name, price,
                         rating, status, description, photo_url)
    VALUES (p_restaurant_id, p_product_category_id, p_name, p_price,
            p_rating, p_status, p_description, p_photo_url);
EXCEPTION
    WHEN check_violation THEN
        RAISE check_violation USING MESSAGE = 'Неверные атрибуты блюда: ' || SQLERRM;
    WHEN not_null_violation THEN
        RAISE not_null_violation USING MESSAGE = 'Не заполнен обязательный атрибут блюда: ' || SQLERRM;
END;
$$;

-- FOOD-106. Заказы читаются один раз. Денежные суммы не размножаются
-- при соединении с позициями: каждый показатель сначала агрегируется отдельно.
CREATE FUNCTION get_statistic() RETURNS TABLE (
    restaurant_name varchar,
    best_product_name varchar,
    total_amount numeric,
    avg_amount numeric,
    best_user varchar
)
LANGUAGE sql VOLATILE SET search_path = konov_food, pg_temp AS $$
    WITH delivered AS MATERIALIZED (
        SELECT order_id, restaurant_id, client_id, total_amount
        FROM "order" WHERE status = 'доставлен'
    ), amounts AS (
        SELECT restaurant_id, sum(total_amount) AS total_amount, avg(total_amount) AS avg_amount
        FROM delivered GROUP BY restaurant_id
    ), product_totals AS (
        SELECT o.restaurant_id, s.product_id, sum(s.quantity) AS quantity
        FROM delivered o JOIN order_structure s USING (order_id)
        GROUP BY o.restaurant_id, s.product_id
    ), best_products AS (
        SELECT DISTINCT ON (restaurant_id) restaurant_id, product_id
        FROM product_totals ORDER BY restaurant_id, quantity DESC, random()
    ), client_totals AS (
        SELECT restaurant_id, client_id, count(*) AS orders
        FROM delivered GROUP BY restaurant_id, client_id
    ), best_clients AS (
        SELECT DISTINCT ON (restaurant_id) restaurant_id, client_id
        FROM client_totals ORDER BY restaurant_id, orders DESC, random()
    )
    SELECT r.restaurant_name, p.product_name, coalesce(a.total_amount, 0),
           coalesce(a.avg_amount, 0), c.login
    FROM restaurant r
    LEFT JOIN amounts a ON a.restaurant_id = r.restaurant_id
    LEFT JOIN best_products bp ON bp.restaurant_id = r.restaurant_id
    LEFT JOIN product p ON p.product_id = bp.product_id
    LEFT JOIN best_clients bc ON bc.restaurant_id = r.restaurant_id
    LEFT JOIN client c ON c.client_id = bc.client_id;
$$;

-- FOOD-107. При повторном расчёте используем сохранённый coefficient_used,
-- поскольку courier.coefficient уже мог стать коэффициентом следующего месяца.
CREATE PROCEDURE courier_salary()
LANGUAGE plpgsql SET search_path = konov_food, pg_temp AS $$
DECLARE
    v_start timestamp := date_trunc('month', localtimestamp);
    v_year integer := extract(year FROM current_date);
    v_month integer := extract(month FROM current_date);
BEGIN
    -- Два одновременных запуска расчёта не должны менять коэффициенты друг друга.
    PERFORM 1 FROM courier ORDER BY courier_id FOR UPDATE;
    INSERT INTO courier_pay AS cp (year, month, courier_id, amount, coefficient_used)
    SELECT v_year, v_month, c.courier_id,
           round(coalesce(old.coefficient_used, c.coefficient) * coalesce(sum(o.commission), 0), 2),
           coalesce(old.coefficient_used, c.coefficient)
    FROM courier c
    LEFT JOIN courier_pay old ON old.courier_id = c.courier_id
        AND old.year = v_year AND old.month = v_month
    LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
        AND o.order_timestamp >= v_start AND o.order_timestamp < v_start + interval '1 month'
    GROUP BY c.courier_id, old.coefficient_used
    ON CONFLICT (year, month, courier_id) DO UPDATE
        SET amount = EXCLUDED.amount;

    WITH deliveries AS (
        SELECT c.courier_id, count(o.order_id) AS n
        FROM courier c
        LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
            AND o.order_timestamp >= v_start AND o.order_timestamp < v_start + interval '1 month'
        WHERE c.status <> 'уволен'
        GROUP BY c.courier_id
    )
    UPDATE courier c SET coefficient = CASE
        WHEN d.n <= 150 THEN 0.1 WHEN d.n <= 250 THEN 0.2
        WHEN d.n <= 500 THEN 0.3 ELSE 0.5 END
    FROM deliveries d WHERE d.courier_id = c.courier_id;
END;
$$;

-- FOOD-108. Рекурсивный CTE заполняет пропуски между календарными месяцами.
CREATE VIEW how_much_money AS
WITH RECURSIVE monthly_orders AS (
    SELECT date_trunc('month', order_timestamp)::date AS month_start,
           sum(order_amount) AS sum_no_commission,
           sum(total_amount) AS sum_with_commission
    FROM "order" WHERE status = 'доставлен'
    GROUP BY 1
), bounds AS (
    SELECT min(month_start) AS first_month, max(month_start) AS last_month FROM monthly_orders
), months(month_start) AS (
    SELECT first_month FROM bounds WHERE first_month IS NOT NULL
    UNION ALL
    SELECT (m.month_start + interval '1 month')::date
    FROM months m CROSS JOIN bounds b WHERE m.month_start < b.last_month
), salaries AS (
    SELECT make_date(year, month, 1) AS month_start, sum(amount) AS courier_pay
    FROM courier_pay GROUP BY year, month
), totals AS (
    SELECT m.month_start,
           coalesce(o.sum_no_commission, 0) AS sum_no_commission,
           coalesce(o.sum_with_commission, 0) AS sum_with_commission,
           coalesce(o.sum_with_commission - o.sum_no_commission, 0) AS commission,
           coalesce(s.courier_pay, 0) AS courier_pay
    FROM months m
    LEFT JOIN monthly_orders o USING (month_start)
    LEFT JOIN salaries s USING (month_start)
), compared AS (
    SELECT *, lag(commission) OVER (ORDER BY month_start) AS prev_commission FROM totals
)
SELECT to_char(month_start, 'YYYY-MM')::text AS year_month,
       sum_no_commission, sum_with_commission, commission, prev_commission,
       commission - prev_commission AS commission_diff,
       courier_pay, commission - courier_pay AS net_profit
FROM compared;
