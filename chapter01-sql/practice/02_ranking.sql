-- ランキング（ROW_NUMBER / RANK / DENSE_RANK）
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 2-1. 3つのランキング関数を比較する -------------------
-- 同じ売上金額の顧客が複数いる場合の違いを確認する

SELECT
    c.name                                                   AS 顧客名,
    SUM(o.total_amount)                                      AS 累計購入金額,
    ROW_NUMBER() OVER (ORDER BY SUM(o.total_amount) DESC)    AS row_number,
    RANK()       OVER (ORDER BY SUM(o.total_amount) DESC)    AS rank,
    DENSE_RANK() OVER (ORDER BY SUM(o.total_amount) DESC)    AS dense_rank
FROM orders o
JOIN customers c ON c.id = o.customer_id
GROUP BY c.id, c.name
ORDER BY 累計購入金額 DESC
LIMIT 15;

-- 確認ポイント:
--   同じ金額の行が複数あるとき ROW_NUMBER は連番（1,2,3）
--   RANK は同位で次が飛ぶ（1,1,3）
--   DENSE_RANK は同位で次が続く（1,1,2）

-- ---- 2-2. 顧客売上ランキング + 全体シェア率 ----------------

SELECT
    c.name                                               AS 顧客名,
    SUM(o.total_amount)                                  AS 累計購入金額,
    RANK() OVER (ORDER BY SUM(o.total_amount) DESC)      AS ランキング,
    ROUND(
        SUM(o.total_amount)
            / SUM(SUM(o.total_amount)) OVER () * 100,
        2
    )                                                    AS 全体シェア率_pct
FROM orders o
JOIN customers c ON c.id = o.customer_id
GROUP BY c.id, c.name
ORDER BY ランキング
LIMIT 20;

-- OVER() が空 = PARTITION BY なし = 全顧客の合計を分母にする

-- ---- 2-3. カテゴリ内商品ランキング（PARTITION BY の威力） --

SELECT
    cat.name                                                      AS カテゴリ,
    p.name                                                        AS 商品名,
    SUM(oi.quantity * oi.unit_price)                              AS 売上合計,
    DENSE_RANK() OVER (
        PARTITION BY cat.id
        ORDER BY SUM(oi.quantity * oi.unit_price) DESC
    )                                                             AS カテゴリ内順位
FROM order_items oi
JOIN products   p   ON p.id   = oi.product_id
JOIN categories cat ON cat.id = p.category_id
GROUP BY cat.id, cat.name, p.id, p.name
ORDER BY cat.name, カテゴリ内順位
LIMIT 30;

-- PARTITION BY cat.id により、カテゴリが変わるたびに順位が 1 にリセットされる

-- ---- 2-4. 実務応用: カテゴリ内上位 3商品だけ抽出 ----------
-- ウィンドウ関数をサブクエリに入れると、順位で行を絞り込める

SELECT カテゴリ, 商品名, 売上合計, カテゴリ内順位
FROM (
    SELECT
        cat.name                                                      AS カテゴリ,
        p.name                                                        AS 商品名,
        SUM(oi.quantity * oi.unit_price)                              AS 売上合計,
        DENSE_RANK() OVER (
            PARTITION BY cat.id
            ORDER BY SUM(oi.quantity * oi.unit_price) DESC
        )                                                             AS カテゴリ内順位
    FROM order_items oi
    JOIN products   p   ON p.id   = oi.product_id
    JOIN categories cat ON cat.id = p.category_id
    GROUP BY cat.id, cat.name, p.id, p.name
) ranked
WHERE カテゴリ内順位 <= 3
ORDER BY カテゴリ, カテゴリ内順位;

-- GROUP BY だけではこの絞り込みは書けない。
-- これが「Top-N per group」パターンで、実務で非常によく使われる。


