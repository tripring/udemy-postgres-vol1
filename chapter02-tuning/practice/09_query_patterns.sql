-- クエリパターンの罠
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- インデックスは正しくても、クエリの書き方で性能が大きく変わります。
-- 現場でよく遭遇するパターンを体験します。


-- ----------------------------------------------------------------
-- 9-1. N+1問題を pg_stat_statements で発見する
-- ----------------------------------------------------------------
-- まず統計をリセットしてから、N+1相当の処理を再現します。

SELECT pg_stat_statements_reset();

-- N+1相当: 顧客1人ずつのループ処理を模擬（100回個別クエリ）
DO $$
DECLARE
    cid INTEGER;
BEGIN
    FOR cid IN SELECT id FROM customers LIMIT 100 LOOP
        PERFORM count(*) FROM orders WHERE customer_id = cid;
    END LOOP;
END $$;

-- pg_stat_statements で calls 異常値を確認
-- 同じクエリが 100 calls になっているはず
SELECT
    calls,
    round(mean_exec_time::NUMERIC, 2) AS mean_ms,
    round(total_exec_time::NUMERIC, 2) AS total_ms,
    left(query, 100) AS query_snippet
FROM pg_stat_statements
WHERE query ILIKE '%orders%customer_id%'
ORDER BY calls DESC
LIMIT 5;
-- → calls = 100 のクエリが見つかれば N+1 の発見成功

-- 解決策: 1回のクエリでまとめて取得
SELECT pg_stat_statements_reset();

SELECT
    c.id,
    c.name,
    count(o.id) AS order_count
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
WHERE c.id <= 100
GROUP BY c.id, c.name;

-- → calls = 1 になっていることを確認
SELECT calls, left(query, 100) AS query_snippet
FROM pg_stat_statements
WHERE query ILIKE '%customers%orders%'
ORDER BY calls DESC LIMIT 5;


-- ----------------------------------------------------------------
-- 9-2. IN（サブクエリ）vs EXISTS vs JOIN のスケール比較
-- ----------------------------------------------------------------

-- 東京都の顧客が発注した注文を取得する3パターン

-- パターン1: IN（サブクエリ）
EXPLAIN ANALYZE
SELECT count(*) FROM orders
WHERE customer_id IN (
    SELECT id FROM customers WHERE prefecture = '東京都'
);

-- パターン2: EXISTS
EXPLAIN ANALYZE
SELECT count(*) FROM orders o
WHERE EXISTS (
    SELECT 1 FROM customers c
    WHERE c.id = o.customer_id
      AND c.prefecture = '東京都'
);

-- パターン3: JOIN
EXPLAIN ANALYZE
SELECT count(*) FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE c.prefecture = '東京都';

-- ↑ 3パターンのactual timeを比較する
-- PostgreSQLのプランナーは賢いのでほぼ同じになることも多いが、
-- サブクエリが大きい場合はEXISTSやJOINが有利になるケースがある


-- ----------------------------------------------------------------
-- 9-3. LIKE 部分一致 と pg_trgm
-- ----------------------------------------------------------------

-- 前方一致: B-tree インデックスが効く
EXPLAIN SELECT * FROM customers WHERE name LIKE '山田%';
-- → 既存のインデックスがあれば Index Scan

-- 部分一致: B-tree インデックスが効かない
EXPLAIN SELECT * FROM customers WHERE name LIKE '%山田%';
-- → Seq Scan（全件スキャン）

-- pg_trgm 拡張を有効化
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- GIN インデックスを作成（名前での部分一致検索用）
CREATE INDEX IF NOT EXISTS idx_customers_name_trgm ON customers USING GIN (name gin_trgm_ops);

-- 部分一致でもインデックスが効くようになる
EXPLAIN SELECT * FROM customers WHERE name LIKE '%山田%';
-- → Bitmap Index Scan on idx_customers_name_trgm

-- 類似度検索（pg_trgm の応用）
-- similarity() 関数で「山田」に近い名前を探す
SELECT name, similarity(name, '山田') AS sim
FROM customers
WHERE name % '山田'  -- % 演算子は similarity > 0.3 のもの
ORDER BY sim DESC
LIMIT 10;

