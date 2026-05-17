-- JSONB 入門
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 5-1. JSONB の中身を確認する --------------------------
-- setup.sql で商品にカテゴリ別の属性が入っている

SELECT id, name, category_id, attributes
FROM products
WHERE attributes IS NOT NULL
ORDER BY category_id, id
LIMIT 15;

-- jsonb_pretty で見やすく整形する
SELECT id, name, jsonb_pretty(attributes) AS 属性詳細
FROM products
WHERE category_id IN (1, 3)    -- 電子機器・衣類ファッション
ORDER BY category_id, id
LIMIT 6;

-- ---- 5-2. 基本演算子（-> と ->>）--------------------------

-- -> : JSON 型（ダブルクォート付き）で返る
SELECT name, attributes -> 'color' AS color_json
FROM products
WHERE category_id = 1
LIMIT 5;

-- ->> : TEXT 型で返る（文字列比較や表示に向く）
SELECT name, attributes ->> 'color' AS color_text
FROM products
WHERE category_id = 1
LIMIT 5;

-- 違いを同時に確認
SELECT
    name,
    attributes -> 'color'    AS json型,
    attributes ->> 'color'   AS text型,
    pg_typeof(attributes -> 'color')   AS json型のデータ型,
    pg_typeof(attributes ->> 'color')  AS text型のデータ型
FROM products
WHERE category_id = 1
LIMIT 3;

-- ---- 5-3. @> 包含演算子（最重要）--------------------------
-- 「このJSONBを含む行を返す」= フィールド検索に使う

-- ブラックの電子機器を検索
SELECT name, attributes
FROM products
WHERE attributes @> '{"color": "ブラック"}';

-- 複数条件を同時に指定（ANDになる）
SELECT name, attributes
FROM products
WHERE attributes @> '{"color": "ブラック"}'
  AND category_id = 3;   -- 衣類ファッション

-- ---- 5-4. GIN インデックスの効果を確認する ----------------

-- インデックスなしの実行計画
EXPLAIN SELECT * FROM products WHERE attributes @> '{"color": "ブラック"}';
-- → Seq Scan（全件スキャン）

-- GIN インデックスを作成
CREATE INDEX IF NOT EXISTS idx_products_attributes
    ON products USING GIN (attributes);

-- インデックスありの実行計画
EXPLAIN SELECT * FROM products WHERE attributes @> '{"color": "ブラック"}';
-- → Bitmap Index Scan on idx_products_attributes（インデックス利用！）

-- ---- 5-5. キーの存在チェック（? 演算子）-------------------

-- 'color' キーを持つ商品だけを対象にする
SELECT attributes ->> 'color' AS カラー, COUNT(*) AS 商品数
FROM products
WHERE attributes ? 'color'
GROUP BY attributes ->> 'color'
ORDER BY 商品数 DESC;

-- ---- 5-6. 数値型として扱う（:: キャスト）------------------
-- ->> は TEXT を返すので数値比較にはキャストが必要

SELECT name, attributes ->> 'warranty_years' AS 保証年数
FROM products
WHERE category_id = 1
  AND (attributes ->> 'warranty_years')::INTEGER >= 2
ORDER BY (attributes ->> 'warranty_years')::INTEGER DESC;

-- ---- 5-7. JSONB を使った集計クエリ -------------------------
-- カラーごとの売上合計（ウィンドウ関数と組み合わせ）

SELECT
    p.attributes ->> 'color'           AS カラー,
    SUM(oi.quantity * oi.unit_price)   AS 売上合計,
    COUNT(DISTINCT oi.order_id)        AS 注文件数
FROM order_items oi
JOIN products p ON p.id = oi.product_id
WHERE p.attributes ? 'color'
GROUP BY p.attributes ->> 'color'
ORDER BY 売上合計 DESC;


