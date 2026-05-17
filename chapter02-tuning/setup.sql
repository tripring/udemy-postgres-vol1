-- ============================================================
-- Chapter 02: パフォーマンスチューニング 事前セットアップ
-- ============================================================
-- このスクリプトは実行に数分かかる場合があります
-- 実行コマンド:
--   psql -f ~/udemy-postgres-vol1/chapter02-tuning/setup.sql
-- ============================================================

-- pg_stat_statements拡張の有効化
-- クエリの実行統計を記録するために必要です
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 実習で作成する検証用オブジェクトを削除し、章を何度でもやり直せるようにする
DROP MATERIALIZED VIEW IF EXISTS mv_daily_sales;
DROP VIEW IF EXISTS v_daily_sales;
DROP TABLE IF EXISTS order_logs_wrong;
DROP TABLE IF EXISTS order_logs_correct;
DROP TABLE IF EXISTS orders_2025;
DROP INDEX IF EXISTS idx_orders_status_ordered_at;
DROP INDEX IF EXISTS idx_order_items_order_id;
DROP INDEX IF EXISTS idx_customers_email_upper;
DROP INDEX IF EXISTS idx_orders_ordered_at;
DROP INDEX IF EXISTS idx_customers_name_trgm;
DROP INDEX IF EXISTS idx_orders_ordered_at_desc;

-- ============================================================
-- 既存データをリセット
-- 外部キー制約がある場合、参照先より参照元を先にTRUNCATE する
-- CASCADE をつけると依存する子テーブルも自動でTRUNCATE される
-- ============================================================
TRUNCATE order_items, orders, inventory, products, categories, customers RESTART IDENTITY CASCADE;

-- ============================================================
-- カテゴリ（10件）
-- ============================================================
INSERT INTO categories (name) VALUES
  ('電子機器'),
  ('家具・インテリア'),
  ('衣類・ファッション'),
  ('食品・飲料'),
  ('書籍・雑誌'),
  ('スポーツ・アウトドア'),
  ('おもちゃ・ホビー'),
  ('美容・コスメ'),
  ('自動車用品'),
  ('その他');

-- ============================================================
-- 商品（1,000件）
-- generate_series で連番を生成し、カテゴリをラウンドロビンで割り当てる
-- price は10円〜50,000円のランダムな値
-- ============================================================
INSERT INTO products (name, category_id, price, description)
SELECT
    'UdeMart商品_' || g,
    ((g - 1) % 10) + 1,
    ((random() * 49990) + 10)::NUMERIC(10, 2),
    'これはUdeMart商品_' || g || 'の説明文です。'
FROM generate_series(1, 1000) g;

-- ============================================================
-- 顧客（100,000件）
-- 都道府県は10都道府県をラウンドロビンで割り当てる
-- ============================================================
INSERT INTO customers (name, email, prefecture)
SELECT
    '顧客_' || g,
    'user_' || g || '@example.com',
    (ARRAY[
        '東京都', '大阪府', '神奈川県', '愛知県', '北海道',
        '福岡県', '埼玉県', '千葉県', '兵庫県', '静岡県'
    ])[(g % 10) + 1]
FROM generate_series(1, 100000) g;

-- ============================================================
-- 注文（300,000件、過去2年分）
-- customer_id はランダムに顧客を割り当て
-- status は 5種類をランダムに設定
-- ordered_at は過去730日以内のランダムな日時
-- shipped_at は約70%の注文に設定（30%はNULL = 未発送）
-- ============================================================
INSERT INTO orders (customer_id, status, ordered_at, shipped_at)
SELECT
    ((random() * 99999) + 1)::INTEGER,
    (ARRAY['pending', 'confirmed', 'shipped', 'delivered', 'cancelled'])
        [(random() * 4 + 1)::INTEGER],
    NOW() - ((random() * 730)::INTEGER || ' days')::INTERVAL
          - ((random() * 86400)::INTEGER || ' seconds')::INTERVAL,
    CASE WHEN random() > 0.3
        THEN NOW() - ((random() * 700)::INTEGER || ' days')::INTERVAL
        ELSE NULL
    END
FROM generate_series(1, 300000);

-- ============================================================
-- 注文明細（600,000件）
-- 1注文あたり平均2件の明細を作成
-- order_id は 1〜300000 をラウンドロビンで割り当て
-- product_id はランダムに商品を割り当て
-- quantity は1〜5個のランダムな数量
-- unit_price は10円〜50,000円のランダムな価格
-- ============================================================
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
    ((g - 1) % 300000) + 1,
    ((random() * 999) + 1)::INTEGER,
    ((random() * 4) + 1)::INTEGER,
    ((random() * 49990) + 10)::NUMERIC(10, 2)
FROM generate_series(1, 600000) g;

-- ============================================================
-- 注文の合計金額を集計して更新
-- order_items の quantity * unit_price の合計を orders.total_amount に反映
-- ============================================================
UPDATE orders o
SET total_amount = sub.total
FROM (
    SELECT order_id, SUM(quantity * unit_price) AS total
    FROM order_items
    GROUP BY order_id
) sub
WHERE o.id = sub.order_id;

-- ============================================================
-- 在庫（全商品分）
-- 全商品に対して在庫レコードを作成（10〜1,010個のランダムな在庫数）
-- ============================================================
INSERT INTO inventory (product_id, quantity)
SELECT
    id,
    ((random() * 1000) + 10)::INTEGER
FROM products;

-- ============================================================
-- 統計情報を更新
-- クエリプランナーが最新のテーブル統計を使えるようにする
-- データ大量挿入後は必ず実行すること
-- ============================================================
ANALYZE;

-- ============================================================
-- 完了確認
-- ============================================================
SELECT
    '完了: カテゴリ'    || (SELECT count(*) FROM categories)  || '件、'
    || '商品'           || (SELECT count(*) FROM products)     || '件、'
    || '顧客'           || (SELECT count(*) FROM customers)    || '件、'
    || '注文'           || (SELECT count(*) FROM orders)       || '件、'
    || '注文明細'       || (SELECT count(*) FROM order_items)  || '件'
    AS summary;
