-- ウィンドウ関数とは何か
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 1-1. GROUP BY との違いを体感する ----------------------
-- GROUP BY: 複数行を 1行に集約する（元の行は消える）

SELECT customer_id, SUM(total_amount) AS 累計金額
FROM orders
GROUP BY customer_id
ORDER BY customer_id
LIMIT 5;
-- → customer_id ごとに 1行だけになる

-- ウィンドウ関数: 各行に集計結果を付与する（元の行は消えない）

SELECT
    id                                                         AS 注文ID,
    customer_id,
    total_amount                                               AS この注文の金額,
    SUM(total_amount) OVER (PARTITION BY customer_id)          AS 顧客の累計金額
FROM orders
ORDER BY customer_id, id
LIMIT 15;
-- → 注文 1件ごとに 1行のまま。さらに「その顧客の累計」が各行に付く
--   同じ customer_id の行は顧客の累計金額がすべて同じ値になる

-- ---- 1-2. OVER() の構成要素を確認する ---------------------
-- PARTITION BY: グループ分け（省略すると全行が 1グループ）
-- ORDER BY: 順序（省略するとランキングや累計は計算できない）

-- PARTITION BY あり: 顧客ごとにリセット
SELECT
    id,
    customer_id,
    total_amount,
    SUM(total_amount) OVER (PARTITION BY customer_id ORDER BY ordered_at) AS 顧客内累計
FROM orders
ORDER BY customer_id, ordered_at
LIMIT 10;

-- PARTITION BY なし: 全体の累計
SELECT
    id,
    customer_id,
    total_amount,
    SUM(total_amount) OVER (ORDER BY ordered_at) AS 全体累計
FROM orders
ORDER BY ordered_at
LIMIT 10;


