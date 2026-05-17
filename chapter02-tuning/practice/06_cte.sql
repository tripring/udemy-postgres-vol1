-- WITH句（CTE）で複雑なJOINを分割する
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- 実務でよく起きる問題：
--   テーブル結合が増えるほど急激に遅くなる。
--   インデックスを追加しても限界がある場合、
--   「先に絞り込んでから結合する」WITH句が有効です。
--
-- ポイント：
--   × 10テーブルを一気にJOIN → プランナーが最適順序を見つけにくい
--   ○ CTE1つあたり3〜4テーブルに留め、行数を減らしてから次の結合へ


-- ----------------------------------------------------------------
-- 6-1. 問題のクエリ：5テーブルを一度にJOINする
-- ----------------------------------------------------------------
-- 「2024年以降に配達完了した注文の、顧客×カテゴリ別の購入合計」
-- JOINが増えるとプランナーが全組み合わせを評価するため急激に重くなる。

\timing on

EXPLAIN ANALYZE
SELECT
    c.name,
    c.prefecture,
    cat.name                         AS category,
    SUM(oi.quantity * oi.unit_price) AS total_spent
FROM customers c
JOIN orders o       ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id   = o.id
JOIN products p     ON p.id          = oi.product_id
JOIN categories cat ON cat.id        = p.category_id
WHERE o.status     = 'delivered'
  AND o.ordered_at >= '2024-01-01'
GROUP BY c.id, c.name, c.prefecture, cat.name
ORDER BY total_spent DESC
LIMIT 20;


-- ----------------------------------------------------------------
-- 6-2. WITH句で「先に絞り込んでから結合する」
-- ----------------------------------------------------------------
-- コツ：
--   ① 最初のCTEで大きなテーブルを条件で絞り込む（件数を圧縮）
--   ② 絞り込んだ小さな中間結果に他のテーブルを結合する
--   ③ 最後に静的なマスタ（顧客・商品）を付加する

EXPLAIN ANALYZE
WITH
-- ① 条件に合う注文だけ先に取り出す（30万件 → 数万件に圧縮）
target_orders AS (
    SELECT id, customer_id
    FROM orders
    WHERE status     = 'delivered'
      AND ordered_at >= '2024-01-01'
),
-- ② 絞り込んだ注文の明細を顧客×商品単位で集計
--    「小さいセット × 大きいセット」ではなく「小さい × 小さい」の結合
spending_summary AS (
    SELECT
        t.customer_id,
        oi.product_id,
        SUM(oi.quantity * oi.unit_price) AS amount
    FROM target_orders t
    JOIN order_items oi ON oi.order_id = t.id
    GROUP BY t.customer_id, oi.product_id
)
-- ③ 最後に顧客・商品カテゴリを付加（静的マスタは最後に結合）
SELECT
    c.name,
    c.prefecture,
    cat.name      AS category,
    SUM(s.amount) AS total_spent
FROM spending_summary s
JOIN customers c    ON c.id   = s.customer_id
JOIN products p     ON p.id   = s.product_id
JOIN categories cat ON cat.id = p.category_id
GROUP BY c.id, c.name, c.prefecture, cat.name
ORDER BY total_spent DESC
LIMIT 20;


-- ----------------------------------------------------------------
-- 6-3. MATERIALIZED オプション（PostgreSQL 12以降）
-- ----------------------------------------------------------------
-- PostgreSQL 12以降、WITH句はデフォルトで「インライン展開」される。
-- = プランナーがCTE境界を越えて最適化できる（良いことが多い）
--
-- ただし「必ず先に評価させたい」場合は MATERIALIZED をつける。
-- = CTEを物理的に一度評価し、その結果を後続で使う（フェンスになる）

EXPLAIN ANALYZE
WITH target_orders AS MATERIALIZED (
    -- このCTEは必ず先に評価される（プランナーが変形しない）
    SELECT id, customer_id
    FROM orders
    WHERE status     = 'delivered'
      AND ordered_at >= '2024-01-01'
),
spending_summary AS MATERIALIZED (
    SELECT
        t.customer_id,
        oi.product_id,
        SUM(oi.quantity * oi.unit_price) AS amount
    FROM target_orders t
    JOIN order_items oi ON oi.order_id = t.id
    GROUP BY t.customer_id, oi.product_id
)
SELECT
    c.name,
    c.prefecture,
    cat.name      AS category,
    SUM(s.amount) AS total_spent
FROM spending_summary s
JOIN customers c    ON c.id   = s.customer_id
JOIN products p     ON p.id   = s.product_id
JOIN categories cat ON cat.id = p.category_id
GROUP BY c.id, c.name, c.prefecture, cat.name
ORDER BY total_spent DESC
LIMIT 20;

-- ★ 使い分けのまとめ ★
-- MATERIALIZED なし（デフォルト）: プランナーに任せる。通常はこちらで十分。
-- MATERIALIZED あり           : 「ここで必ず絞り込む」と明示したいとき。
--                               デバッグや、複雑なクエリで想定外の最適化を防ぎたいとき。

\timing off


