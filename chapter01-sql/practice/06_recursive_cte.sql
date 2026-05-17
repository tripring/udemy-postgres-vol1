-- 再帰CTE（WITH RECURSIVE）
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- 階層構造を持つデータを、深さに関わらず一度に取得するための構文。
-- UdeMartのカテゴリは parent_id を持つ自己参照テーブル。
-- ============================================================

-- ---- 6-1. カテゴリの親子関係を確認する --------------------
SELECT id, name, parent_id
FROM categories
ORDER BY parent_id NULLS FIRST, id;

-- ---- 6-2. 全カテゴリツリーを取得する ----------------------
-- アンカー部: parent_id IS NULL のルートカテゴリを起点にする
-- 再帰部: 前の結果の id を parent_id に持つ行を探す

WITH RECURSIVE category_tree AS (
    -- アンカー: ルートカテゴリ（親を持たない）
    SELECT
        id,
        name,
        parent_id,
        0        AS depth,
        name::text AS path
    FROM categories
    WHERE parent_id IS NULL

    UNION ALL

    -- 再帰: 子カテゴリを順に取得
    SELECT
        c.id,
        c.name,
        c.parent_id,
        ct.depth + 1,
        ct.path || ' > ' || c.name
    FROM categories c
    JOIN category_tree ct ON c.parent_id = ct.id
)
SELECT
    depth,
    REPEAT('  ', depth) || name  AS インデント表示,
    path
FROM category_tree
ORDER BY path;

-- depth=0 がルート、depth=1 がその子カテゴリ
-- 現在のテストデータは parent_id が NULL 以外のカテゴリがないため
-- depth=0 だけ表示される（サブカテゴリ追加で多層が確認できる）

-- ---- 6-3. サブカテゴリのデモデータを追加して試す ----------
-- 学習用に階層構造を作る（後で削除可能）

INSERT INTO categories (name, parent_id) VALUES
    ('スマートフォン',   1),  -- 電子機器の子
    ('ノートPC',        1),  -- 電子機器の子
    ('iPhoneアクセサリ', (SELECT id FROM categories WHERE name = 'スマートフォン')),
    ('Androidアクセサリ',(SELECT id FROM categories WHERE name = 'スマートフォン'));

-- 再度ツリーを表示（3階層になっているはず）
WITH RECURSIVE category_tree AS (
    SELECT id, name, parent_id, 0 AS depth, name::text AS path
    FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.name, c.parent_id, ct.depth + 1, ct.path || ' > ' || c.name
    FROM categories c JOIN category_tree ct ON c.parent_id = ct.id
)
SELECT depth, REPEAT('  ', depth) || name AS インデント表示, path
FROM category_tree ORDER BY path;

-- ---- 6-4. 特定カテゴリの配下をすべて取得する --------------
-- 「電子機器」(id=1) とその全サブカテゴリを取得する

WITH RECURSIVE sub_categories AS (
    SELECT id, name FROM categories WHERE id = 1    -- 起点
    UNION ALL
    SELECT c.id, c.name
    FROM categories c
    JOIN sub_categories sc ON c.parent_id = sc.id
)
SELECT * FROM sub_categories;

-- ---- 6-5. 配下カテゴリの商品を取得する --------------------

WITH RECURSIVE sub_categories AS (
    SELECT id FROM categories WHERE id = 1
    UNION ALL
    SELECT c.id FROM categories c
    JOIN sub_categories sc ON c.parent_id = sc.id
)
SELECT p.name, p.price, cat.name AS カテゴリ名
FROM products p
JOIN categories cat ON cat.id = p.category_id
WHERE p.category_id IN (SELECT id FROM sub_categories)
ORDER BY p.price DESC
LIMIT 10;

-- ---- 6-6. 深さの上限を設ける（無限ループ防止）-----------
-- 循環参照データがあると無限ループになる可能性がある。
-- depth に上限を設けると安全。

WITH RECURSIVE category_tree AS (
    SELECT id, name, parent_id, 0 AS depth
    FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.name, c.parent_id, ct.depth + 1
    FROM categories c
    JOIN category_tree ct ON c.parent_id = ct.id
    WHERE ct.depth < 10    -- ← 最大10階層まで（無限ループ防止）
)
SELECT * FROM category_tree ORDER BY depth, id;

