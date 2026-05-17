-- パーティションプルーニングを確認する
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ------------------------------------------------------------
-- 4-1. 特定の月に絞ったクエリで EXPLAIN ANALYZE を実行する
--
-- 確認ポイント:
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
-- 実行計画に3つの子パーティションだけが出ることを確認する。
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, FORMAT TEXT)
SELECT count(*), sum(total_amount)
FROM orders_partitioned
WHERE ordered_at >= '2023-11-01' AND ordered_at < '2024-02-01';


-- ------------------------------------------------------------
-- 4-4. 悪化体験：パーティションキーを使わないと速くならない
--
-- customer_id だけで検索すると、どの月のパーティションにあるか判断できない。
-- そのため、多くのパーティションを見に行く必要がある。
-- 「パーティショニングしたのに遅い」典型例。
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, FORMAT TEXT)
SELECT count(*), sum(total_amount)
FROM orders_partitioned
WHERE customer_id = 100;


-- ------------------------------------------------------------
-- 4-5. 悪化体験：日付列を関数で包むと判断しづらくなる
--
-- DATE_TRUNC('month', ordered_at) = ... は人間には月指定に見えるが、
-- PostgreSQLから見ると ordered_at の素直な範囲条件ではない。
-- パーティションプルーニングを効かせたいなら、下のOK例のように範囲で書く。
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, FORMAT TEXT)
SELECT count(*), sum(total_amount)
FROM orders_partitioned
WHERE DATE_TRUNC('month', ordered_at) = TIMESTAMP '2024-01-01';

-- OK: パーティションキーを範囲条件で書く
EXPLAIN (ANALYZE, FORMAT TEXT)
SELECT count(*), sum(total_amount)
FROM orders_partitioned
WHERE ordered_at >= '2024-01-01' AND ordered_at < '2024-02-01';


-- ------------------------------------------------------------
-- 4-6. 判断の練習
-- ------------------------------------------------------------
-- Q1. 4-1 と 4-4 で、スキャン対象のパーティション数はどう違いますか？
-- Q2. 4-5 のNG例とOK例で、実行時間や計画はどう変わりましたか？
-- Q3. アプリ側の検索条件に ordered_at が入らない画面でも、
--     このパーティショニングは効果があると言えますか？
--
-- 実務での結論:
--   パーティショニングはテーブルを分けるだけでは効かない。
--   よく使うWHERE条件がパーティションキーと一致しているときに効果が出る。
