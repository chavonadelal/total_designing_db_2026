-- FOOD-101. Установка в пустую подготовленную БД; exts уже существует.
CREATE SCHEMA konov_food;
SET search_path TO konov_food, exts;

CREATE TYPE restaurant_status AS ENUM ('активен', 'неактивен');
CREATE TYPE product_status AS ENUM ('доступно', 'нет_в_наличии', 'архив');
CREATE TYPE courier_status AS ENUM ('свободен', 'занят', 'на_доставке', 'уволен');
CREATE TYPE order_status AS ENUM ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');
CREATE TYPE order_pay_status AS ENUM ('ожидает', 'оплачен', 'ошибка');
CREATE TYPE payment_status AS ENUM ('успех', 'ошибка', 'в_обработке');
CREATE TYPE payment_type AS ENUM ('карта', 'наличные', 'безнал');
CREATE TYPE review_entity_type AS ENUM ('блюдо', 'ресторан', 'заказ');

CREATE TABLE client (
    client_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    login varchar(80) NOT NULL UNIQUE CHECK (btrim(login) <> ''),
    password varchar(32) NOT NULL CHECK (password ~ '^[0-9a-f]{32}$'),
    phone_number varchar(12) NOT NULL UNIQUE CHECK (phone_number ~ '^\+7[0-9]{10}$')
);

CREATE TABLE address (
    address_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    street varchar(120) NOT NULL CHECK (btrim(street) <> ''),
    house_number varchar(20) NOT NULL CHECK (btrim(house_number) <> ''),
    apartment_office varchar(20) CHECK (btrim(apartment_office) <> ''),
    CONSTRAINT address_physical_unique UNIQUE NULLS NOT DISTINCT (street, house_number, apartment_office)
);

CREATE TABLE client_address (
    client_id uuid REFERENCES client(client_id),
    address_id uuid REFERENCES address(address_id),
    PRIMARY KEY (client_id, address_id)
);

CREATE TABLE restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(120) NOT NULL CHECK (btrim(restaurant_name) <> ''),
    address_id uuid NOT NULL UNIQUE REFERENCES address(address_id),
    description text NOT NULL CHECK (btrim(description) <> ''),
    work_start time NOT NULL,
    work_end time NOT NULL CHECK (work_end > work_start),
    company_details text NOT NULL CHECK (btrim(company_details) <> ''),
    rating numeric(3,2) CHECK (rating BETWEEN 0 AND 5),
    status restaurant_status NOT NULL
);

CREATE TABLE courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    fio varchar(150) NOT NULL CHECK (btrim(fio) <> ''),
    phone_number varchar(12) NOT NULL CHECK (phone_number ~ '^\+7[0-9]{10}$'),
    status courier_status NOT NULL,
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric(2,1) NOT NULL DEFAULT 0.1 CHECK (coefficient BETWEEN 0.1 AND 0.5),
    CHECK (status <> 'уволен' OR dismissal_date IS NOT NULL),
    CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date)
);

CREATE TABLE courier_pay (
    year integer NOT NULL CHECK (year > 0),
    month integer NOT NULL CHECK (month BETWEEN 1 AND 12),
    courier_id uuid REFERENCES courier(courier_id),
    amount numeric(16,2) NOT NULL CHECK (amount >= 0 AND amount <> 'NaN'::numeric),
    coefficient_used numeric(2,1) NOT NULL CHECK (coefficient_used BETWEEN 0.1 AND 0.5),
    PRIMARY KEY (year, month, courier_id)
);

CREATE TABLE product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(80) NOT NULL CHECK (btrim(product_category_name) <> '')
);

CREATE TABLE product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(120) NOT NULL CHECK (btrim(product_name) <> ''),
    product_category_id uuid NOT NULL REFERENCES product_category(product_category_id),
    price numeric(12,2) NOT NULL CHECK (price >= 0 AND price <> 'NaN'::numeric),
    restaurant_id uuid NOT NULL REFERENCES restaurant(restaurant_id),
    photo_url text CHECK (photo_url ~ '^https?://[^[:space:]]+$'),
    rating numeric(3,2) CHECK (rating BETWEEN 0 AND 5),
    status product_status NOT NULL,
    description text NOT NULL CHECK (btrim(description) <> '')
);

CREATE TABLE "order" (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES courier(courier_id),
    client_id uuid NOT NULL REFERENCES client(client_id),
    address_id uuid NOT NULL REFERENCES address(address_id),
    restaurant_id uuid NOT NULL REFERENCES restaurant(restaurant_id),
    order_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    delivery_timestamp timestamp,
    order_amount numeric(14,2) NOT NULL CHECK (order_amount >= 0 AND order_amount <> 'NaN'::numeric),
    commission numeric(14,2) GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED,
    total_amount numeric(14,2) GENERATED ALWAYS AS (order_amount + round(order_amount * 0.10, 2)) STORED,
    status order_status NOT NULL,
    pay_status order_pay_status NOT NULL DEFAULT 'ожидает',
    description text NOT NULL CHECK (btrim(description) <> ''),
    FOREIGN KEY (client_id, address_id) REFERENCES client_address(client_id, address_id),
    UNIQUE (order_id, restaurant_id),
    UNIQUE (order_id, total_amount),
    CHECK (total_amount >= 1000),
    CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL),
    CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp)
);

CREATE TABLE order_structure (
    order_id uuid REFERENCES "order"(order_id),
    product_id uuid REFERENCES product(product_id),
    quantity numeric(10,3) NOT NULL CHECK (quantity > 0 AND quantity <> 'NaN'::numeric),
    -- Цена на момент заказа: изменение меню не меняет историю покупок.
    unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0 AND unit_price <> 'NaN'::numeric),
    PRIMARY KEY (order_id, product_id)
);

CREATE TABLE payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL,
    type payment_type NOT NULL,
    amount numeric(14,2) NOT NULL CHECK (amount >= 0 AND amount <> 'NaN'::numeric),
    transaction_reference varchar(100) NOT NULL UNIQUE CHECK (btrim(transaction_reference) <> ''),
    transaction_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    status payment_status NOT NULL,
    FOREIGN KEY (order_id, amount) REFERENCES "order"(order_id, total_amount)
);
CREATE UNIQUE INDEX payment_one_success ON payment(order_id) WHERE status = 'успех';

CREATE TABLE review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    -- Автор однозначно определяется через order.client_id (3НФ).
    order_id uuid NOT NULL REFERENCES "order"(order_id),
    review_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    entity_id uuid NOT NULL,
    entity_type review_entity_type NOT NULL,
    description text NOT NULL CHECK (btrim(description) <> ''),
    photo_url text CHECK (photo_url ~ '^https?://[^[:space:]]+$'),
    rating numeric(3,2) NOT NULL CHECK (rating BETWEEN 1 AND 5),
    -- Технические вычисляемые колонки маршрутизируют FK для полиморфной ссылки.
    product_id uuid GENERATED ALWAYS AS (CASE WHEN entity_type = 'блюдо' THEN entity_id END) STORED,
    restaurant_id uuid GENERATED ALWAYS AS (CASE WHEN entity_type = 'ресторан' THEN entity_id END) STORED,
    FOREIGN KEY (order_id, product_id) REFERENCES order_structure(order_id, product_id),
    FOREIGN KEY (order_id, restaurant_id) REFERENCES "order"(order_id, restaurant_id),
    UNIQUE (order_id, entity_type, entity_id),
    CHECK (entity_type <> 'заказ' OR entity_id = order_id)
);

CREATE INDEX order_restaurant_delivered ON "order"(restaurant_id) WHERE status = 'доставлен';
CREATE INDEX order_courier_month ON "order"(courier_id, order_timestamp) WHERE status = 'доставлен';
CREATE INDEX order_structure_product ON order_structure(product_id);
CREATE INDEX review_entity ON review(entity_type, entity_id);
CREATE INDEX payment_order ON payment(order_id);
