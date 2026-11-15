SET search_path TO konov_food, exts;

-- Цена фиксируется в позиции заказа, а не берётся из меняющегося меню.
CREATE FUNCTION set_order_price() RETURNS trigger
LANGUAGE plpgsql SET search_path = konov_food, pg_temp AS $$
BEGIN
    IF NEW.unit_price IS NULL THEN
        SELECT price INTO NEW.unit_price FROM product WHERE product_id = NEW.product_id;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER order_price BEFORE INSERT ON order_structure
FOR EACH ROW EXECUTE FUNCTION set_order_price();

-- Заказ и его позиции вставляются разными SQL-командами.
-- Проверка итогового состояния откладывается до конца транзакции.
CREATE FUNCTION check_order_contents() RETURNS trigger
LANGUAGE plpgsql SET search_path = konov_food, pg_temp AS $$
DECLARE
    v_ids uuid[] := '{}';
    v_id uuid;
    v_restaurant uuid;
    v_amount numeric;
    v_count bigint;
    v_sum numeric;
    v_wrong_restaurant boolean;
BEGIN
    IF TG_TABLE_NAME = 'product' THEN
        SELECT array_agg(order_id) INTO v_ids
        FROM order_structure WHERE product_id = NEW.product_id;
    ELSE
        IF TG_OP <> 'INSERT' THEN v_ids := array_append(v_ids, OLD.order_id); END IF;
        IF TG_OP <> 'DELETE' THEN v_ids := array_append(v_ids, NEW.order_id); END IF;
    END IF;

    FOR v_id IN SELECT DISTINCT unnest(v_ids) LOOP
        SELECT restaurant_id, order_amount INTO v_restaurant, v_amount
        FROM "order" WHERE order_id = v_id;
        IF NOT FOUND THEN CONTINUE; END IF;

        SELECT count(*), sum(round(s.quantity * s.unit_price, 2)),
               bool_or(p.restaurant_id <> v_restaurant)
        INTO v_count, v_sum, v_wrong_restaurant
        FROM order_structure s JOIN product p USING (product_id)
        WHERE s.order_id = v_id;

        IF v_count = 0 THEN
            RAISE check_violation USING MESSAGE = 'Заказ должен содержать хотя бы одну позицию (BR-7.14)';
        END IF;
        IF v_wrong_restaurant THEN
            RAISE check_violation USING MESSAGE = 'Все блюда заказа должны быть из его ресторана (BR-7.3)';
        END IF;
        IF v_sum <> v_amount THEN
            RAISE check_violation USING MESSAGE = 'Сумма заказа должна совпадать со стоимостью его позиций (BR-7.10)';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER order_contents
AFTER INSERT OR UPDATE OF order_amount, restaurant_id ON "order"
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_order_contents();
CREATE CONSTRAINT TRIGGER order_structure_contents
AFTER INSERT OR UPDATE OR DELETE ON order_structure
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_order_contents();
CREATE CONSTRAINT TRIGGER product_restaurant_contents
AFTER UPDATE OF restaurant_id ON product
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_order_contents();

-- BR-8.7. Статус заказа всегда выводится из попыток оплаты.
CREATE FUNCTION sync_pay_status() RETURNS trigger
LANGUAGE plpgsql SET search_path = konov_food, pg_temp AS $$
DECLARE
    v_ids uuid[] := '{}';
    v_id uuid;
    v_status order_pay_status;
BEGIN
    IF TG_TABLE_NAME = 'order' THEN
        v_ids := ARRAY[NEW.order_id];
    ELSE
        IF TG_OP <> 'INSERT' THEN v_ids := array_append(v_ids, OLD.order_id); END IF;
        IF TG_OP <> 'DELETE' THEN v_ids := array_append(v_ids, NEW.order_id); END IF;
    END IF;

    FOR v_id IN SELECT DISTINCT unnest(v_ids) LOOP
        SELECT CASE
            WHEN bool_or(status = 'успех') THEN 'оплачен'
            WHEN count(*) > 0 AND bool_and(status = 'ошибка') THEN 'ошибка'
            ELSE 'ожидает'
        END::order_pay_status INTO v_status
        FROM payment WHERE order_id = v_id;

        IF TG_TABLE_NAME = 'order' THEN
            NEW.pay_status := v_status;
        ELSE
            UPDATE "order" SET pay_status = v_status
            WHERE order_id = v_id AND pay_status IS DISTINCT FROM v_status;
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;
CREATE TRIGGER order_pay_status BEFORE INSERT OR UPDATE OF pay_status ON "order"
FOR EACH ROW EXECUTE FUNCTION sync_pay_status();
CREATE TRIGGER payment_pay_status AFTER INSERT OR UPDATE OR DELETE ON payment
FOR EACH ROW EXECUTE FUNCTION sync_pay_status();

-- FOOD-105. При UPDATE учитываются и старый, и новый адресаты отзыва.
CREATE FUNCTION rating_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = konov_food, pg_temp AS $$
DECLARE
    v_old_type review_entity_type;
    v_old_id uuid;
    v_new_type review_entity_type;
    v_new_id uuid;
    v_target record;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_type := OLD.entity_type;
        v_old_id := OLD.entity_id;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_type := NEW.entity_type;
        v_new_id := NEW.entity_id;
    END IF;
    FOR v_target IN
        SELECT DISTINCT t.entity_type, t.entity_id
        FROM (VALUES (v_old_type, v_old_id), (v_new_type, v_new_id)) AS t(entity_type, entity_id)
        WHERE t.entity_id IS NOT NULL
        ORDER BY t.entity_type, t.entity_id
    LOOP
        IF v_target.entity_type = 'блюдо' THEN
            -- Сначала блокируем адресата, затем читаем отзывы: второй параллельный
            -- пересчёт увидит уже зафиксированный результат первой транзакции.
            PERFORM 1 FROM product WHERE product_id = v_target.entity_id FOR NO KEY UPDATE;
            UPDATE product SET rating = (
                SELECT round(avg(rating), 2) FROM review
                WHERE entity_type = 'блюдо' AND entity_id = v_target.entity_id
            ) WHERE product_id = v_target.entity_id;
        ELSIF v_target.entity_type = 'ресторан' THEN
            PERFORM 1 FROM restaurant WHERE restaurant_id = v_target.entity_id FOR NO KEY UPDATE;
            UPDATE restaurant SET rating = (
                SELECT round(avg(rating), 2) FROM review
                WHERE entity_type = 'ресторан' AND entity_id = v_target.entity_id
            ) WHERE restaurant_id = v_target.entity_id;
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE TRIGGER review_rating_change AFTER INSERT OR UPDATE OR DELETE ON review
FOR EACH ROW EXECUTE FUNCTION rating_change();
