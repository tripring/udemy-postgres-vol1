-- 前後行の参照（LAG / LEAD）
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 4-1. 前月比を計算する ---------------------------------
-- LAG(値, N): N行前の値を返す。先頭行は NULL になる

SELECT
    月,
    月次売上,
    前月売上,
    CASE
        WHEN 前月売上 IS NULL THEN NULL
        ELSE ROUND((月次売上 - 前月売上) / 前月売上 * 100, 1)
    END AS 前月比_pct
FROM (
    SELECT
        TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
        SUM(total_amount)                                   AS 月次売上,
        LAG(SUM(total_amount), 1) OVER (
            ORDER BY DATE_TRUNC('month', ordered_at)
        )                                                   AS 前月売上
    FROM orders
    WHERE ordered_at >= '2024-01-01'
    GROUP BY DATE_TRUNC('month', ordered_at)
) t
ORDER BY 月;

-- サブクエリで LAG を計算してから外側で比率を計算すると
-- LAG() の呼び出しが 1回で済んで読みやすい

-- ---- 4-2. LEAD で翌月売上を並べる -------------------------
-- LEAD(値, N): N行後の値を返す。末尾行は NULL になる

SELECT
    TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
    ROUND(SUM(total_amount), 0)                         AS 今月売上,
    ROUND(
        LEAD(SUM(total_amount), 1) OVER (
            ORDER BY DATE_TRUNC('month', ordered_at)
        ),
        0
    )                                                   AS 翌月売上
FROM orders
WHERE ordered_at >= '2024-01-01'
GROUP BY DATE_TRUNC('month', ordered_at)
ORDER BY 月;

-- ---- 4-3. 顧客の購入間隔を分析する ------------------------
-- 各顧客の注文間隔（前回購入から何日後か）を計算する

SELECT
    c.name                                               AS 顧客名,
    o.ordered_at::date                                   AS 注文日,
    o.total_amount                                       AS 注文金額,
    LAG(o.ordered_at::date) OVER (
        PARTITION BY o.customer_id
        ORDER BY o.ordered_at
    )                                                    AS 前回注文日,
    (o.ordered_at::date - LAG(o.ordered_at::date) OVER (
        PARTITION BY o.customer_id
        ORDER BY o.ordered_at
    ))                                                   AS 購入間隔_日
FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.customer_id IN (
    SELECT customer_id FROM orders
    GROUP BY customer_id
    HAVING COUNT(*) >= 3        -- 3回以上購入した顧客に絞る
)
ORDER BY o.customer_id, o.ordered_at
LIMIT 20;

-- 活用: 購入間隔が 90日以上の顧客に再訪促進メールを送る施策に使える

-- ---- 4-4. FIRST_VALUE / LAST_VALUE の活用 -----------------
-- 初回購入日と最終購入日を各注文行に付与する

SELECT
    c.name                                               AS 顧客名,
    o.ordered_at::date                                   AS 注文日,
    FIRST_VALUE(o.ordered_at::date) OVER (
        PARTITION BY o.customer_id
        ORDER BY o.ordered_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    )                                                    AS 初回購入日,
    LAST_VALUE(o.ordered_at::date) OVER (
        PARTITION BY o.customer_id
        ORDER BY o.ordered_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    )                                                    AS 最終購入日
FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.customer_id <= 5
ORDER BY o.customer_id, o.ordered_at;

-- LAST_VALUE は「パーティション内の最終行」が欲しいので
-- ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING が必要
-- （省略するとデフォルトが「現在行まで」になり正しく動かない）


