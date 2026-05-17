-- 統計情報のズレとプランナーの誤判断
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- PostgreSQLのプランナーは「統計情報」を元に実行計画を立てます。
-- 統計が古いと最悪の実行計画を選んでしまいます。


-- 10-1. 現在の統計情報を確認する
-- ----------------------------------------------------------------
-- pg_stat_user_tables でテーブルの推定行数と最終ANALYZE日時を確認
SELECT
    relname                             AS table_name,
    n_live_tup                          AS estimated_rows,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;


-- 10-2. 統計が古いと起きる問題を体験する
-- ----------------------------------------------------------------
-- 新しいテーブルを作り、大量データを入れた後にANALYZEなしで検索する

DROP TABLE IF EXISTS orders_2025;

CREATE TABLE orders_2025 AS
SELECT * FROM orders WHERE false;  -- スキーマのみコピー

ALTER TABLE orders_2025 ADD PRIMARY KEY (id);
CREATE INDEX idx_orders_2025_customer_id ON orders_2025 (customer_id);
CREATE INDEX idx_orders_2025_status_ordered_at ON orders_2025 (status, ordered_at DESC);

-- ANALYZEなしで1万件投入
INSERT INTO orders_2025
SELECT * FROM orders LIMIT 10000;

-- EXPLAIN ANALYZE で予測行数と実測行数のズレを確認
-- rows= が予測、actual rows= が実測です。
-- ANALYZE前は統計が薄いため、予測が外れやすいことを確認します。
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_2025 WHERE status = 'delivered';
-- ↑ rows= と actual rows= の差に注目

-- ANALYZE を実行して統計を更新
ANALYZE orders_2025;

-- ANALYZE後にもう一度確認
-- rows= が actual rows= に近づいていれば、統計情報が効いている証拠です。
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_2025 WHERE status = 'delivered';
-- ↑ 実行時間だけでなく「予測の精度」が改善したかを見る


-- 10-3. 予測行数と実際の行数のズレを確認する
-- ----------------------------------------------------------------
-- EXPLAIN ANALYZE で rows（予測）と actual rows（実測）を比較する
EXPLAIN ANALYZE
SELECT * FROM orders WHERE status = 'delivered' AND ordered_at >= '2024-06-01';

-- rows= と actual rows= の差を確認する
-- 10倍以上の乖離があれば ANALYZE を実行する


-- 10-4. 手動 ANALYZE（大量データ投入後やバッチ後に実行）
-- ----------------------------------------------------------------
ANALYZE orders;
ANALYZE customers;
ANALYZE order_items;

-- VACUUM ANALYZE は VACUUM（デッドタプル回収）と ANALYZE を同時に実行
VACUUM ANALYZE orders;


-- 10-5. 拡張統計（複数カラムの相関）
-- ----------------------------------------------------------------
-- customer_id と status の組み合わせには相関がある
-- （特定の顧客は cancelled が多い、など）
-- 単独カラムの統計だけでは組み合わせの実態を表せない

-- 拡張統計を作成
CREATE STATISTICS IF NOT EXISTS stat_orders_cust_status
    ON customer_id, status FROM orders;

ANALYZE orders;

-- EXPLAIN で (customer_id, status) の組み合わせ絞り込みの推定精度を確認
-- 拡張統計あり/なしで estimated rows の精度が変わる
EXPLAIN SELECT count(*) FROM orders
WHERE customer_id = 1 AND status = 'delivered';
