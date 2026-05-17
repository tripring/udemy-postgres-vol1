-- ============================================================
-- Chapter 03: トランザクション・ロック制御 事前セットアップ
-- ============================================================
-- 実行方法:
--   psql -f ~/udemy-postgres-vol1/chapter03-transaction/setup.sql
-- ============================================================

-- 既存データをリセット（外部キー制約があるため順番に注意）
TRUNCATE order_items, orders, inventory, products, categories, customers RESTART IDENTITY CASCADE;

-- ============================================================
-- カテゴリ
-- ============================================================
INSERT INTO categories (name) VALUES
  ('電子機器'),
  ('その他');

-- ============================================================
-- 商品（在庫が少ないものを含む）
-- ============================================================
INSERT INTO products (name, category_id, price, description) VALUES
  ('限定版ワイヤレスイヤホン',       1, 12800.00, '数量限定！人気のワイヤレスイヤホン'),
  ('スマートウォッチ Pro',           1,  9800.00, 'ベストセラースマートウォッチ'),
  ('モバイルバッテリー 20000mAh',    1,  4980.00, '大容量モバイルバッテリー');

-- ============================================================
-- 顧客
-- ============================================================
INSERT INTO customers (name, email, prefecture) VALUES
  ('田中 太郎', 'tanaka@example.com', '東京都'),
  ('鈴木 花子', 'suzuki@example.com', '大阪府'),
  ('佐藤 次郎', 'sato@example.com',   '神奈川県');

-- ============================================================
-- 在庫（商品1は残り1個！）
-- ============================================================
INSERT INTO inventory (product_id, quantity) VALUES
  (1,   1),   -- 限定版イヤホン: 残り1個（今回の問題の舞台）
  (2,  50),   -- スマートウォッチ: 50個
  (3, 100);   -- モバイルバッテリー: 100個

-- ============================================================
-- セットアップ確認
-- ============================================================
SELECT '=== セットアップ完了 ===' AS msg;

SELECT '--- 商品一覧 ---' AS msg;
SELECT id, name, price FROM products ORDER BY id;

SELECT '--- 在庫確認 ---' AS msg;
SELECT
    p.name          AS 商品名,
    i.quantity      AS 在庫数
FROM inventory i
JOIN products p ON p.id = i.product_id
ORDER BY i.product_id;

SELECT '--- 顧客一覧 ---' AS msg;
SELECT id, name, email, prefecture FROM customers ORDER BY id;
