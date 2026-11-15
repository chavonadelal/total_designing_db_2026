-- FOOD-109. Выполняется администратором, в том числе после pg_restore.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    END IF;
END;
$$;
ALTER ROLE inspector WITH LOGIN PASSWORD 'NetoSQL2025';
ALTER ROLE inspector SET search_path TO konov_food, exts;

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO inspector', current_database());
END;
$$;
GRANT ALL PRIVILEGES ON SCHEMA konov_food TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA konov_food TO inspector;
GRANT ALL PRIVILEGES ON ALL ROUTINES IN SCHEMA konov_food TO inspector;
GRANT USAGE ON TYPE konov_food.restaurant_status, konov_food.product_status,
    konov_food.courier_status, konov_food.order_status, konov_food.order_pay_status,
    konov_food.payment_status, konov_food.payment_type, konov_food.review_entity_type TO inspector;
GRANT USAGE ON SCHEMA exts, information_schema, pg_catalog TO inspector;
GRANT EXECUTE ON FUNCTION exts.uuid_generate_v4() TO inspector;
