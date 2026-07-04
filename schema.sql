-- Schema for a small e-commerce retailer ("Cartwheel & Co.")
-- SQLite 3.25+ (window functions required by queries.sql)
--
-- Five tables:
--   categories   product taxonomy
--   products     catalog with list price and unit cost
--   customers    one row per signup, with acquisition channel
--   orders       one row per checkout; status tracks returns/cancellations
--   order_items  line items; unit_price is the price actually paid
--                (after any discount), so revenue is computed from here,
--                not from the catalog price

PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS categories;

CREATE TABLE categories (
    category_id   INTEGER PRIMARY KEY,
    category_name TEXT NOT NULL UNIQUE
);

CREATE TABLE products (
    product_id   INTEGER PRIMARY KEY,
    category_id  INTEGER NOT NULL REFERENCES categories(category_id),
    product_name TEXT NOT NULL,
    list_price   REAL NOT NULL CHECK (list_price > 0),
    unit_cost    REAL NOT NULL CHECK (unit_cost > 0)
);

CREATE TABLE customers (
    customer_id INTEGER PRIMARY KEY,
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    email       TEXT NOT NULL UNIQUE,
    city        TEXT NOT NULL,
    state       TEXT NOT NULL,
    channel     TEXT NOT NULL CHECK (channel IN
                    ('organic', 'paid_search', 'social', 'referral')),
    signup_date TEXT NOT NULL                      -- ISO yyyy-mm-dd
);

CREATE TABLE orders (
    order_id    INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    order_date  TEXT NOT NULL,                     -- ISO yyyy-mm-dd
    status      TEXT NOT NULL CHECK (status IN
                    ('completed', 'returned', 'cancelled'))
);

CREATE TABLE order_items (
    order_item_id INTEGER PRIMARY KEY,
    order_id      INTEGER NOT NULL REFERENCES orders(order_id),
    product_id    INTEGER NOT NULL REFERENCES products(product_id),
    quantity      INTEGER NOT NULL CHECK (quantity > 0),
    unit_price    REAL NOT NULL CHECK (unit_price > 0)
);

-- the queries join and filter on these constantly
CREATE INDEX idx_orders_customer   ON orders(customer_id);
CREATE INDEX idx_orders_date       ON orders(order_date);
CREATE INDEX idx_items_order       ON order_items(order_id);
CREATE INDEX idx_items_product     ON order_items(product_id);
