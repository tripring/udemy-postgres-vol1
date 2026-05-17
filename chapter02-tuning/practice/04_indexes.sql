-- インデックスを追加して速くする
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- インデックスはテーブルの「索引」です。
-- WHERE条件や JOIN条件で使われるカラムにインデックスを貼ることで
-- 全件スキャン（Seq Scan）を避けて必要な行だけに素早くアクセスできます。


-- 4-1. 現在のインデックスを確認する
-- ----------------------------------------------------------------
-- PRIMARY KEY と UNIQUE 制約にはPostgreSQLが自動でインデックスを作成します。
-- それ以外のカラムには手動で作成する必要があります。
SELECT
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE tablename IN ('orders', 'order_items', 'customers')
ORDER BY tablename, indexname;


-- 4-2. ordersテーブルに複合インデックスを追加する
-- ----------------------------------------------------------------
-- WHERE status = 'delivered' AND ordered_at >= '2024-01-01' の検索を高速化します。
--
-- 複合インデックスのカラム順序の原則:
--   「等値条件（=）のカラム → 範囲条件（>=, <=, BETWEEN）のカラム」
--
-- status = 'delivered' が等値条件 → 先に置く
-- ordered_at >= '2024-01-01' が範囲条件 → 後に置く
-- DESC はより新しい日付から検索することが多いためのヒント
CREATE INDEX IF NOT EXISTS idx_orders_status_ordered_at
    ON orders (status, ordered_at DESC);


-- 4-3. order_itemsにもインデックスを追加する
-- ----------------------------------------------------------------
-- JOIN order_items oi ON oi.order_id = o.id の結合を高速化します。
-- order_id で頻繁に検索されるため、このインデックスは効果的です。
CREATE INDEX IF NOT EXISTS idx_order_items_order_id
    ON order_items (order_id);


-- 4-4. インデックス追加後にEXPLAIN ANALYZEを再実行して比較する
-- ----------------------------------------------------------------
-- 「Index Scan using idx_orders_status_ordered_at」に変わっているはずです。
-- actual time が大幅に短くなっていることを確認してください。
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    c.name,
    c.prefecture,
    COUNT(o.id)                      AS order_count,
    SUM(oi.quantity * oi.unit_price) AS total_spent
FROM customers c
JOIN orders o       ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id   = o.id
WHERE o.status     = 'delivered'
  AND o.ordered_at >= '2024-01-01'
GROUP BY c.id, c.name, c.prefecture
ORDER BY total_spent DESC
LIMIT 20;
-- ↑ 「Index Scan using idx_orders_status_ordered_at」に変わっているか確認
--   actual time が Section 3 の結果と比べて大幅に短くなっているか確認


-- 4-5. インデックスのサイズを確認する
-- ----------------------------------------------------------------
-- インデックスはディスクスペースを消費します。
-- pg_relation_size でインデックスのサイズを確認できます。
-- インデックスが多すぎると書き込み（INSERT/UPDATE/DELETE）も遅くなるため
-- 本当に必要なインデックスだけを追加することが重要です。
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS index_size
FROM pg_indexes
WHERE tablename = 'orders';

