-- 集計ウィンドウ（累計・移動平均）
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 3-1. 月次売上の累計（Running Total）------------------

SELECT
    TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
    SUM(total_amount)                                   AS 月次売上,
    SUM(SUM(total_amount)) OVER (
        ORDER BY DATE_TRUNC('month', ordered_at)
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                   AS 年初来累計
FROM orders
WHERE ordered_at >= '2024-01-01'
GROUP BY DATE_TRUNC('month', ordered_at)
ORDER BY 月;

-- ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW:
--   「先頭行から現在行まで」= 累計になる

-- ---- 3-2. 直近 3ヶ月の移動平均 ----------------------------

SELECT
    TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
    ROUND(SUM(total_amount), 0)                         AS 月次売上,
    ROUND(
        AVG(SUM(total_amount)) OVER (
            ORDER BY DATE_TRUNC('month', ordered_at)
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
        0
    )                                                   AS 直近3ヶ月移動平均
FROM orders
WHERE ordered_at >= '2024-01-01'
GROUP BY DATE_TRUNC('month', ordered_at)
ORDER BY 月;

-- ROWS BETWEEN 2 PRECEDING AND CURRENT ROW:
--   「2行前〜現在行（計3行）の平均」
--   月次変動のノイズを除いてトレンドを見るのに有効

-- ---- 3-3. 売上の全体に占める割合を各月に付与 ---------------

SELECT
    TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
    ROUND(SUM(total_amount), 0)                         AS 月次売上,
    ROUND(
        SUM(total_amount) / SUM(SUM(total_amount)) OVER () * 100,
        1
    )                                                   AS 年間シェア_pct
FROM orders
WHERE ordered_at >= '2024-01-01'
GROUP BY DATE_TRUNC('month', ordered_at)
ORDER BY 月;


