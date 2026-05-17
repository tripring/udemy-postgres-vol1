-- 現状確認
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ------------------------------------------------------------
-- 1-1. テーブルサイズを確認する
--
-- pg_size_pretty: バイト数を「40 MB」「1.2 GB」などの読みやすい形式に変換
-- pg_total_relation_size: テーブル本体 + インデックスの合計サイズ
-- pg_relation_size: テーブル本体のみのサイズ
-- ------------------------------------------------------------
SELECT
    relname                                                          AS table_name,
    pg_size_pretty(pg_total_relation_size(oid))                     AS total_size,
    pg_size_pretty(pg_relation_size(oid))                           AS table_size,
    pg_size_pretty(pg_total_relation_size(oid) - pg_relation_size(oid)) AS index_size
FROM pg_class
WHERE relname = 'orders';


-- ------------------------------------------------------------
-- 1-2. 月次売上レポートの実行時間を確認する（EXPLAIN ANALYZE）
--
-- ポイント: "Seq Scan on orders" と表示されることを確認する
-- 全500,000件を読んでいるため、rows=500000 になっているはず
-- ------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    DATE_TRUNC('month', ordered_at) AS month,
    count(*)                        AS order_count,
    sum(total_amount)               AS revenue
FROM orders
GROUP BY 1
ORDER BY 1;


-- ------------------------------------------------------------
-- 1-3. 特定の月だけに絞っても全件スキャンになることを確認
--
-- パーティショニングなしの通常テーブルでは WHERE があっても
-- インデックスが ordered_at に存在しない限り Seq Scan になる
-- ------------------------------------------------------------
EXPLAIN ANALYZE
SELECT
    DATE_TRUNC('day', ordered_at) AS day,
    count(*)                      AS order_count,
    sum(total_amount)             AS revenue
FROM orders
-- ★ TIMESTAMP列にBETWEENを使うと '2024-01-31 00:00:01' 以降が抜ける！
-- ★ 日付範囲は「以上 AND 未満」パターンが正確
WHERE ordered_at >= '2024-01-01' AND ordered_at < '2024-02-01'
GROUP BY 1
ORDER BY 1;


