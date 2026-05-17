-- UdeMart 共通スキーマ定義
-- Chapter 00で手動実行します

-- pg_stat_statements拡張（スロークエリ調査で使用）
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ============================================================
-- 顧客テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS customers (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    email       VARCHAR(200) NOT NULL UNIQUE,
    prefecture  VARCHAR(50),
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- カテゴリテーブル（階層構造）
-- ============================================================
CREATE TABLE IF NOT EXISTS categories (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    parent_id   INTEGER REFERENCES categories(id)
);

-- ============================================================
-- 商品テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS products (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(200) NOT NULL,
    category_id INTEGER REFERENCES categories(id),
    price       NUMERIC(10, 2) NOT NULL,
    description TEXT,
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- 注文テーブル
-- status: pending / confirmed / shipped / delivered / cancelled
-- ============================================================
CREATE TABLE IF NOT EXISTS orders (
    id           SERIAL PRIMARY KEY,
    customer_id  INTEGER NOT NULL REFERENCES customers(id),
    status       VARCHAR(20) NOT NULL DEFAULT 'pending',
    total_amount NUMERIC(12, 2),
    ordered_at   TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    shipped_at   TIMESTAMP WITH TIME ZONE
);

-- ============================================================
-- 注文明細テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS order_items (
    id          SERIAL PRIMARY KEY,
    order_id    INTEGER NOT NULL REFERENCES orders(id),
    product_id  INTEGER NOT NULL REFERENCES products(id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL
);

-- ============================================================
-- 在庫テーブル
-- ============================================================
CREATE TABLE IF NOT EXISTS inventory (
    id          SERIAL PRIMARY KEY,
    product_id  INTEGER NOT NULL UNIQUE REFERENCES products(id),
    quantity    INTEGER NOT NULL DEFAULT 0,
    updated_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
