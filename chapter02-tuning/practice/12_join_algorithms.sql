-- EXPLAIN の結合アルゴリズム（Hash Join / Nested Loop / Merge Join）
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 12-1. 結合アルゴリズムの種類 ---------------------------

-- PostgreSQL は JOIN を実行する際、自動的に最適なアルゴリズムを選ぶ
-- EXPLAIN の出力に以下のいずれかが表示される：
--   Hash Join      … 大きなテーブル同士の等値結合に使いやすい
--   Nested Loop    … 小さなテーブル or インデックスがある結合に有効
--   Merge Join     … ソート済みデータ同士の等値結合に使う

-- ---- 12-2. Hash Join を観察する ----------------------------

-- Hash Join: 内側テーブルをハッシュテーブルに展開し、外側をスキャンして照合
-- → テーブルが大きくても O(N+M) で済む
-- → 事前ソートが不要

EXPLAIN ANALYZE
SELECT
    o.id AS order_id,
    c.name AS customer_name,
    o.total_amount
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE o.ordered_at >= '2024-01-01'
LIMIT 100;

-- EXPLAIN 出力の読み方：
--   Hash Join  (cost=... rows=...)
--     Hash Cond: (o.customer_id = c.id)
--     ->  Seq Scan on orders o       ← 外側（probe）
--     ->  Hash                        ← ハッシュテーブル構築
--           ->  Seq Scan on customers ← 内側（build）

-- Hash の行（Batches, Memory Usage）でハッシュテーブルのサイズがわかる

-- ---- 12-3. Nested Loop を観察する --------------------------

-- Nested Loop: 外側の各行に対して内側をループ
-- → 外側が少行 + 内側にインデックスがある場合に最速
-- → 外側が大きいと O(N*M) になり遅い

-- order_items → products (product_id にインデックスあり)
EXPLAIN ANALYZE
SELECT
    oi.order_id,
    p.name AS product_name,
    oi.quantity,
    oi.unit_price
FROM order_items oi
JOIN products p ON oi.product_id = p.id
WHERE oi.order_id = 1;

-- EXPLAIN 出力の読み方：
--   Nested Loop  (cost=... rows=...)
--     ->  Index Scan on order_items  ← 外側（order_id で絞り込み）
--     ->  Index Scan on products     ← 内側（product_id のインデックス使用）

-- ---- 12-4. 強制的にアルゴリズムを変えてコストを比較する ----

-- PostgreSQL はアルゴリズムを ON/OFF できる（学習・検証用）

-- Hash Join を無効化して Nested Loop を強制
SET enable_hashjoin = off;

EXPLAIN ANALYZE
SELECT
    o.id,
    c.name,
    o.total_amount
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE o.ordered_at >= '2024-01-01'
LIMIT 100;

-- コスト・実行時間を Hash Join と比較してみる

-- 設定を元に戻す
RESET enable_hashjoin;

-- Nested Loop を無効化
SET enable_nestloop = off;

EXPLAIN ANALYZE
SELECT
    oi.order_id,
    p.name,
    oi.quantity
FROM order_items oi
JOIN products p ON oi.product_id = p.id
WHERE oi.order_id = 1;

RESET enable_nestloop;

-- ---- 12-5. Merge Join を観察する ---------------------------

-- Merge Join: 両テーブルをソートしてからマージ
-- → 両側がソート済み（インデックス順）なら追加ソートなし
-- → 等値結合かつ大きなテーブル同士で両側にインデックスがあると使われることがある

-- Merge Join が選ばれやすい条件を作る
SET enable_hashjoin = off;
SET enable_nestloop = off;

EXPLAIN ANALYZE
SELECT
    o.id,
    c.name
FROM orders o
JOIN customers c ON o.customer_id = c.id
ORDER BY o.customer_id
LIMIT 1000;

-- EXPLAIN 出力の読み方：
--   Merge Join  (cost=... rows=...)
--     Merge Cond: (o.customer_id = c.id)
--     ->  Sort on orders (or Index Scan)
--     ->  Sort on customers (or Index Scan)

RESET enable_hashjoin;
RESET enable_nestloop;

-- ---- 12-6. 実務での判断：アルゴリズムの選択基準 ------------

SELECT '状況' AS situation, '選ばれやすいアルゴリズム' AS algorithm, '理由' AS reason
UNION ALL
SELECT '外側が少行 + 内側にインデックス', 'Nested Loop', 'インデックスで内側を高速に引ける'
UNION ALL
SELECT '大きなテーブル同士の等値結合', 'Hash Join', 'ソート不要でメモリ内で完結'
UNION ALL
SELECT '両側がソート済み（インデックス順）', 'Merge Join', '追加ソートなしでマージできる'
UNION ALL
SELECT '複数テーブルの複雑な JOIN', 'Hash Join が多い', 'プランナが最適コストを選択';

-- ---- 12-7. Hash Join でメモリ不足が起きる場合 --------------

-- Hash テーブルが work_mem を超えるとディスクに書き出す（遅くなる）
SHOW work_mem;

-- Batches > 1 の場合はディスクスピル発生（EXPLAIN 出力で確認）
-- 対策：work_mem を増やす（セッション単位で変更可能）

SET work_mem = '64MB';

EXPLAIN ANALYZE
SELECT
    o.id,
    c.name,
    SUM(oi.unit_price * oi.quantity)
FROM orders o
JOIN customers c ON o.customer_id = c.id
JOIN order_items oi ON o.id = oi.order_id
GROUP BY o.id, c.name
LIMIT 100;

RESET work_mem;

-- Batches の値が 1 → メモリ内で完結（速い）
-- Batches の値が N > 1 → ディスクスピル（work_mem を増やすか、クエリを分割する）

-- ---- 12-8. まとめ：EXPLAIN で結合アルゴリズムを読む --------

-- ポイント：
-- 1. Hash Join が基本。大テーブル同士の等値結合に強い
-- 2. Nested Loop はインデックス使用時に最速。外側が少行のとき
-- 3. Merge Join はソート済みデータのマージ。等値結合で両側インデックスがあれば
-- 4. Batches > 1 → work_mem 不足のサイン → SET work_mem = 'XMB' で確認
-- 5. 強制変更（enable_hashjoin=off 等）は本番では使わず検証のみに使う
