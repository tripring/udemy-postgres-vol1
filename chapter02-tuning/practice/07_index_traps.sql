-- インデックスが効かない3つの罠
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- インデックスを作ったのに Seq Scan が出る——その原因は大抵この3つです。
-- それぞれ「なぜ効かないか」を EXPLAIN で確認し、対処法を試します。


-- ----------------------------------------------------------------
-- 7-1. 罠①：型ミスマッチ（暗黙キャストでインデックス無効）
-- ----------------------------------------------------------------
-- 外部キーの型が親テーブルと違うと、JOINのたびにキャストが走り
-- インデックスが効かなくなります。現場ではよく起きます。

-- デモ用テーブル: order_id を NUMERIC にしてしまったケース
DROP TABLE IF EXISTS order_logs_wrong;
DROP TABLE IF EXISTS order_logs_correct;

CREATE TABLE order_logs_wrong (
    id          SERIAL PRIMARY KEY,
    order_id    NUMERIC NOT NULL,  -- ← 本来は INTEGER だが間違えた
    event       TEXT,
    created_at  TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- データを10万件挿入
INSERT INTO order_logs_wrong (order_id, event)
SELECT
    (random() * 299999 + 1)::NUMERIC,
    'event_' || i
FROM generate_series(1, 100000) AS i;

-- インデックスを作る
CREATE INDEX IF NOT EXISTS idx_order_logs_wrong_order_id ON order_logs_wrong(order_id);

ANALYZE order_logs_wrong;

-- JOIN で確認: orders.id (INTEGER) と order_logs_wrong.order_id (NUMERIC) の比較
-- キャストが発生してインデックスが無視される
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.status, l.event
FROM orders o
JOIN order_logs_wrong l ON o.id = l.order_id  -- INTEGER = NUMERIC の比較
WHERE o.id = 1000;
-- ↑ Seq Scan on order_logs_wrong が出るか、キャストが走っているか確認

-- 正しい型のテーブルと比較
CREATE TABLE order_logs_correct (
    id          SERIAL PRIMARY KEY,
    order_id    INTEGER NOT NULL,  -- ← 親テーブルと同じ型
    event       TEXT,
    created_at  TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO order_logs_correct (order_id, event)
SELECT order_id::INTEGER, event FROM order_logs_wrong;

CREATE INDEX IF NOT EXISTS idx_order_logs_correct_order_id ON order_logs_correct(order_id);
ANALYZE order_logs_correct;

-- 型が合っていれば Index Scan になる
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.status, l.event
FROM orders o
JOIN order_logs_correct l ON o.id = l.order_id  -- INTEGER = INTEGER
WHERE o.id = 1000;
-- ↑ Index Scan が使われていることを確認

-- 型ミスマッチを検出するクエリ（自分のDBで確認したいとき）
SELECT
    tc.table_name          AS child_table,
    kcu.column_name        AS fk_column,
    c.data_type            AS fk_type,
    ccu.table_name         AS parent_table,
    ccu.column_name        AS pk_column,
    c2.data_type           AS pk_type
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
    AND tc.table_schema = ccu.table_schema
JOIN information_schema.columns c
    ON c.table_name = tc.table_name
    AND c.column_name = kcu.column_name
    AND c.table_schema = tc.table_schema
JOIN information_schema.columns c2
    ON c2.table_name = ccu.table_name
    AND c2.column_name = ccu.column_name
    AND c2.table_schema = ccu.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND c.data_type != c2.data_type;  -- 型が違う外部キーだけ表示


-- ----------------------------------------------------------------
-- 7-2. 罠②：関数でくるんでインデックス無効
-- ----------------------------------------------------------------
-- WHERE句でカラムを関数に通すと、B-treeインデックスが使えなくなります。

-- customers.email には UNIQUE インデックスが存在する（\d customers で確認）
EXPLAIN SELECT * FROM customers WHERE email = 'user1@example.com';
-- → Index Scan（インデックスが効いている）

-- UPPER() でくるむとインデックスが効かなくなる
EXPLAIN SELECT * FROM customers WHERE UPPER(email) = 'USER1@EXAMPLE.COM';
-- → Seq Scan（インデックスが無視される）

-- 解決策①: 式インデックスを作る
CREATE INDEX IF NOT EXISTS idx_customers_email_upper ON customers (UPPER(email));

-- 式インデックス作成後は UPPER() でもインデックスが効く
EXPLAIN SELECT * FROM customers WHERE UPPER(email) = 'USER1@EXAMPLE.COM';
-- → Index Scan on idx_customers_email_upper

-- ----------------------------------------------------------------
-- 日付のキャストパターン
-- ----------------------------------------------------------------
-- ordered_at にはインデックスがあると仮定（Section 4で作成済み）

-- NG: ::date でキャストするとインデックスが効かない
EXPLAIN SELECT count(*) FROM orders
WHERE ordered_at::date = '2024-06-15';
-- → Seq Scan（キャストでインデックス無効）

-- OK: 範囲条件に書き換えるとインデックスが効く
EXPLAIN SELECT count(*) FROM orders
WHERE ordered_at >= '2024-06-15' AND ordered_at < '2024-06-16';
-- → Index Scan（インデックスが効いている）


-- ----------------------------------------------------------------
-- 7-3. 罠③：複合インデックスの先頭列をスキップ
-- ----------------------------------------------------------------
-- (status, ordered_at) の複合インデックスを使って実験します。
-- Section 4で作成した idx_orders_status_ordered_at が存在することを確認

-- OK: 先頭列(status)を等値条件で使っている
EXPLAIN SELECT count(*) FROM orders
WHERE status = 'delivered' AND ordered_at >= '2024-01-01';
-- → Index Scan using idx_orders_status_ordered_at

-- NG: 先頭列(status)を省略している
EXPLAIN SELECT count(*) FROM orders
WHERE ordered_at >= '2024-01-01';
-- → Seq Scan（先頭列なしではインデックスが効かない）

-- ordered_at だけで検索が必要なら、単独インデックスを追加する
CREATE INDEX IF NOT EXISTS idx_orders_ordered_at ON orders (ordered_at DESC);

EXPLAIN SELECT count(*) FROM orders
WHERE ordered_at >= '2024-01-01';
-- → Index Scan using idx_orders_ordered_at

