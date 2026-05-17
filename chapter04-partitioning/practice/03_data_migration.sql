-- データ移行
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ------------------------------------------------------------
-- 3-1. 既存 orders テーブルからデータを移行する
--
-- INSERT ... SELECT で全行を一括コピーする。
-- PostgreSQL がパーティションキー（ordered_at）を見て
-- 自動的に正しい子パーティションにルーティングする。
--
-- ※ 500,000件の移行は数秒〜数十秒かかります。
-- ------------------------------------------------------------
INSERT INTO orders_partitioned
    (id, customer_id, status, total_amount, ordered_at, shipped_at)
SELECT
    id, customer_id, status, total_amount, ordered_at, shipped_at
FROM orders;


-- ------------------------------------------------------------
-- 3-2. シーケンスを移行後の最大IDに合わせる
--
-- id を明示指定して一括コピーしたため、シーケンスが更新されていない。
-- このまま次のステップで INSERT するとシーケンスがid=1から始まり
-- Primary Key 重複エラーになる。移行後に必ず実行すること。
-- ------------------------------------------------------------
SELECT setval(
    pg_get_serial_sequence('orders_partitioned', 'id'),
    (SELECT MAX(id) FROM orders_partitioned)
);


-- ------------------------------------------------------------
-- 3-3. 件数が一致しているか確認する
-- ------------------------------------------------------------
SELECT
    (SELECT count(*) FROM orders)              AS original_count,
    (SELECT count(*) FROM orders_partitioned)  AS partitioned_count;


-- ------------------------------------------------------------
-- 3-4. 各パーティションの件数とサイズを確認する
--
-- 月ごとにデータが分散されていることを確認できる。
-- ------------------------------------------------------------
SELECT
    child.relname                               AS partition_name,
    pg_size_pretty(pg_relation_size(child.oid)) AS size,
    pg_stat_user_tables.n_live_tup              AS approx_rows
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child  ON pg_inherits.inhrelid  = child.oid
JOIN pg_stat_user_tables ON pg_stat_user_tables.relname = child.relname
WHERE parent.relname = 'orders_partitioned'
ORDER BY child.relname;


