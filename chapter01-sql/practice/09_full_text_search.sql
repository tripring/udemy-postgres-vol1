-- 全文検索（tsvector / tsquery）
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================
--
-- 【注意】PostgreSQL 16 の標準インストールには日本語テキスト検索設定が
-- 含まれていません。このファイルでは 'simple' 設定（スペース区切り）を
-- 使用します。本番環境の日本語全文検索には pg_bigm や pgroonga 拡張を
-- 使用してください。
-- ============================================================

-- ---- 9-0. デモ用商品を追加 -----------------------------------
-- 'simple' 設定でも動作するよう、スペース区切りの英語/混在表現を使う

INSERT INTO products (name, category_id, price, description)
VALUES
    ('Wireless Earphone Pro',   1, 19800, 'wireless bluetooth noise cancelling earphone'),
    ('Bluetooth Speaker Mini',  1, 8900,  'portable wireless bluetooth speaker waterproof'),
    ('USB-C Cable 2m',          1, 1980,  'high speed charging cable usb type-c compatible'),
    ('ノイズキャンセリング ヘッドホン', 1, 34800, 'wireless noise cancelling headphone premium quality'),
    ('ワイヤレス 充電器 Qi',     1, 4980,  'wireless charger qi standard fast charging compatible')
ON CONFLICT DO NOTHING;

-- ---- 9-1. LIKE 検索との比較 ----------------------------------
-- まず LIKE の限界を体験する

-- 「wireless」を含む商品を LIKE で検索
EXPLAIN ANALYZE
SELECT id, name FROM products WHERE description LIKE '%wireless%';

-- インデックスが使えないことを確認
-- → Seq Scan になる（中間一致は常にフルスキャン）

-- ---- 9-2. tsvector で文書をトークナイズする ------------------

-- to_tsvector: テキストを全文検索用のトークン列（lexeme）に変換
SELECT to_tsvector('simple', 'wireless bluetooth noise cancelling earphone');
-- → 'bluetooth':2 'cancelling':4 'earphone':5 'noise':3 'wireless':1

-- 商品データをトークナイズして確認
SELECT
    id,
    name,
    to_tsvector('simple', name || ' ' || COALESCE(description, '')) AS search_vec
FROM products
WHERE description IS NOT NULL
LIMIT 5;

-- ---- 9-3. tsquery で検索クエリを作る ------------------------

-- to_tsquery: 検索語をクエリ形式に変換
SELECT to_tsquery('simple', 'wireless');
SELECT to_tsquery('simple', 'wireless & bluetooth');  -- AND
SELECT to_tsquery('simple', 'wireless | usb');         -- OR

-- plainto_tsquery: 自然文から自動的に検索クエリを生成（& でつなぐ）
SELECT plainto_tsquery('simple', 'wireless noise cancelling');
-- → 'wireless' & 'noise' & 'cancelling'

-- ---- 9-4. @@ 演算子で全文検索する --------------------------

-- tsvector @@ tsquery = マッチするか
SELECT
    id,
    name,
    description
FROM products
WHERE to_tsvector('simple', name || ' ' || COALESCE(description, ''))
    @@ to_tsquery('simple', 'wireless');

-- LIKE との結果を比べてみる
SELECT id, name, description FROM products WHERE description LIKE '%wireless%';
-- 結果は同じでも、インデックス使用の有無が大きく異なる

-- ---- 9-5. tsvector 列を追加して高速化する -------------------

-- 毎回 to_tsvector() を計算するのはコスト高
-- → 専用カラムにインデックスを作ることで高速化

-- 全文検索用の列を追加
ALTER TABLE products ADD COLUMN IF NOT EXISTS search_vec tsvector;

-- 既存データを更新
UPDATE products
SET search_vec = to_tsvector('simple', name || ' ' || COALESCE(description, ''));

-- GIN インデックスを作成（全文検索に最適なインデックス種別）
CREATE INDEX IF NOT EXISTS idx_products_search_vec ON products USING GIN (search_vec);

-- インデックスを使って検索
EXPLAIN ANALYZE
SELECT id, name
FROM products
WHERE search_vec @@ to_tsquery('simple', 'wireless');

-- → Bitmap Index Scan on idx_products_search_vec になることを確認
-- LIKE '%wireless%' と比べて実行計画の違いを見る

-- ---- 9-6. AND / OR 検索 ------------------------------------

-- AND 検索: 両方のキーワードを含む商品
SELECT id, name, description
FROM products
WHERE search_vec @@ to_tsquery('simple', 'wireless & bluetooth');

-- OR 検索: どちらかのキーワードを含む商品
SELECT id, name, description
FROM products
WHERE search_vec @@ to_tsquery('simple', 'wireless | usb');

-- ---- 9-7. ts_rank でスコアリング ----------------------------

-- マッチ度を数値で返す（高いほど関連性が高い）
SELECT
    id,
    name,
    description,
    ts_rank(search_vec, to_tsquery('simple', 'wireless & bluetooth')) AS rank
FROM products
WHERE search_vec @@ to_tsquery('simple', 'wireless & bluetooth')
ORDER BY rank DESC;

-- ---- 9-8. ts_headline でハイライト表示 ---------------------

-- 検索キーワードをハイライトして返す（検索結果表示UIで使う）
SELECT
    id,
    name,
    ts_headline(
        'simple',
        COALESCE(description, name),
        to_tsquery('simple', 'wireless'),
        'StartSel=<b>, StopSel=</b>, MaxWords=20, MinWords=5'
    ) AS highlighted
FROM products
WHERE search_vec @@ to_tsquery('simple', 'wireless');

-- ---- 9-9. トリガーで search_vec を自動更新 ------------------

-- INSERT/UPDATE のたびに手動 UPDATE するのは忘れがち
-- → トリガーで自動化する

CREATE OR REPLACE FUNCTION update_product_search_vec()
RETURNS TRIGGER AS $$
BEGIN
    NEW.search_vec := to_tsvector('simple',
        NEW.name || ' ' || COALESCE(NEW.description, ''));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_product_search_vec ON products;
CREATE TRIGGER trg_product_search_vec
    BEFORE INSERT OR UPDATE OF name, description ON products
    FOR EACH ROW EXECUTE FUNCTION update_product_search_vec();

-- 動作確認：新商品を登録すると search_vec が自動設定される
INSERT INTO products (name, category_id, price, description)
VALUES ('量子ノイズキャンセリングイヤホン Pro', 1, 29800, 'wireless quantum noise cancelling premium');

SELECT id, name, search_vec
FROM products
WHERE name LIKE '%量子%';

-- ---- 9-10. まとめ：LIKE vs 全文検索 -------------------------

-- | 方法           | インデックス使用 | スコアリング | 備考                      |
-- |---------------|----------------|------------|--------------------------|
-- | LIKE '%x%'    | ✗（Seq Scan）  | ✗          | 中間一致は常にフルスキャン    |
-- | LIKE 'x%'     | ○（前方一致）   | ✗          | 前方一致のみインデックス有効  |
-- | tsvector/GIN  | ○              | ○          | 大量データで真価を発揮       |

-- 日本語全文検索を本番環境で使う場合：
--   ・pg_bigm 拡張: n-gram方式。追加設定のみで日本語対応（DB側）
--   ・pgroonga 拡張: 高機能。groongaエンジンベース
--   ・LIKE + pg_trgm 拡張: %x% 検索にもインデックスを使えるようにする

-- クリーンアップ
DELETE FROM products WHERE name LIKE '%量子%';
DROP TRIGGER IF EXISTS trg_product_search_vec ON products;
DROP FUNCTION IF EXISTS update_product_search_vec();
ALTER TABLE products DROP COLUMN IF EXISTS search_vec;
DELETE FROM products WHERE name IN (
    'Wireless Earphone Pro', 'Bluetooth Speaker Mini', 'USB-C Cable 2m',
    'ノイズキャンセリング ヘッドホン', 'ワイヤレス 充電器 Qi'
);
