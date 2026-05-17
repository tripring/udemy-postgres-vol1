-- パーティションプルーニングを確認する
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ------------------------------------------------------------
-- 4-1. 特定の月に絞ったクエリで EXPLAIN ANALYZE を実行する
--
-- 確認ポイント:
--   - "Partitions selected: 1" と表示されること
--   - "orders_2024_01" だけがスキャン対象になっていること
--   - 元の orders テーブルより actual time が短いこと
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, FORMAT TEXT)
SELECT
    DATE_TRUNC('day', ordered_at) AS day,
    count(*)                      AS order_count,
    sum(total_amount)             AS revenue
FROM orders_partitioned
WHERE ordered_at >= '2024-01-01' AND ordered_at < '2024-02-01'
GROUP BY 1
ORDER BY 1;


-- ------------------------------------------------------------
-- 4-2. 比較：元の orders テーブルで同じクエリを実行する
--
-- orders は全件スキャン（Seq Scan / Bitmap Heap Scan on orders）
-- orders_partitioned はプルーニングで 1 パーティションのみスキャン
-- ------------------------------------------------------------
-- 元のテーブル（全500,000件をスキャン）
EXPLAIN ANALYZE
SELECT
    DATE_TRUNC('day', ordered_at) AS day,
    count(*)                      AS order_count,
    sum(total_amount)             AS revenue
FROM orders
WHERE ordered_at >= '2024-01-01' AND ordered_at < '2024-02-01'
GROUP BY 1
ORDER BY 1;

-- パーティションテーブル（2024年1月パーティションのみスキャン）
EXPLAIN ANALYZE
SELECT
    DATE_TRUNC('day', ordered_at) AS day,
    count(*)                      AS order_count,
    sum(total_amount)             AS revenue
FROM orders_partitioned
WHERE ordered_at >= '2024-01-01' AND ordered_at < '2024-02-01'
GROUP BY 1
ORDER BY 1;


-- ------------------------------------------------------------
-- 4-3. 年をまたぐ範囲では複数パーティションが選択される
--
-- WHERE ordered_at BETWEEN '2023-11-01' AND '2024-01-31' の場合、
-- 2023-11, 2023-12, 2024-01 の 3 パーティションが選択される。
-- "Partitions selected: 3" と表示されることを確認する。
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, FORMAT TEXT)
SELECT count(*), sum(total_amount)
FROM orders_partitioned
WHERE ordered_at >= '2023-11-01' AND ordered_at < '2024-02-01';


