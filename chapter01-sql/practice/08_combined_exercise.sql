-- 総合演習（ウィンドウ関数 + JSONB の組み合わせ）
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 6-1. 月次・カテゴリ別売上と前月比を一覧にする ---------
-- 実際のダッシュボードで使えるレベルのクエリ

SELECT
    月,
    カテゴリ,
    月次売上,
    LAG(月次売上) OVER (PARTITION BY カテゴリ ORDER BY 月) AS 前月売上,
    CASE
        WHEN LAG(月次売上) OVER (PARTITION BY カテゴリ ORDER BY 月) IS NULL THEN NULL
        ELSE ROUND(
            (月次売上 - LAG(月次売上) OVER (PARTITION BY カテゴリ ORDER BY 月))
            / LAG(月次売上) OVER (PARTITION BY カテゴリ ORDER BY 月) * 100,
            1
        )
    END AS 前月比_pct
FROM (
    SELECT
        TO_CHAR(DATE_TRUNC('month', o.ordered_at), 'YYYY-MM') AS 月,
        cat.name                                              AS カテゴリ,
        ROUND(SUM(oi.quantity * oi.unit_price), 0)           AS 月次売上
    FROM orders o
    JOIN order_items oi ON oi.order_id   = o.id
    JOIN products    p  ON p.id          = oi.product_id
    JOIN categories cat ON cat.id        = p.category_id
    WHERE o.ordered_at >= '2024-01-01'
    GROUP BY DATE_TRUNC('month', o.ordered_at), cat.id, cat.name
) t
ORDER BY カテゴリ, 月;

-- ---- 6-2. カラー別の月次売上ランキング（JSONB + ウィンドウ関数）

SELECT
    月,
    カラー,
    月次売上,
    RANK() OVER (PARTITION BY 月 ORDER BY 月次売上 DESC) AS 月内順位
FROM (
    SELECT
        TO_CHAR(DATE_TRUNC('month', o.ordered_at), 'YYYY-MM') AS 月,
        p.attributes ->> 'color'                              AS カラー,
        ROUND(SUM(oi.quantity * oi.unit_price), 0)           AS 月次売上
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products    p  ON p.id        = oi.product_id
    WHERE p.attributes ? 'color'
      AND o.ordered_at >= '2024-01-01'
    GROUP BY DATE_TRUNC('month', o.ordered_at), p.attributes ->> 'color'
) t
ORDER BY 月, 月内順位;


-- ============================================================
-- まとめ確認クエリ
-- ============================================================

-- ウィンドウ関数で皆川くんの「月次レポート」を再現してみる
SELECT
    TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
    ROUND(SUM(total_amount), 0)                         AS 月次売上,
    ROUND(
        SUM(SUM(total_amount)) OVER (
            ORDER BY DATE_TRUNC('month', ordered_at)
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ), 0
    )                                                   AS 年初来累計,
    ROUND(
        AVG(SUM(total_amount)) OVER (
            ORDER BY DATE_TRUNC('month', ordered_at)
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ), 0
    )                                                   AS 移動平均_3ヶ月,
    CASE
        WHEN LAG(SUM(total_amount)) OVER (
            ORDER BY DATE_TRUNC('month', ordered_at)
        ) IS NULL THEN NULL
        ELSE ROUND(
            (SUM(total_amount) - LAG(SUM(total_amount)) OVER (
                ORDER BY DATE_TRUNC('month', ordered_at)
            )) / LAG(SUM(total_amount)) OVER (
                ORDER BY DATE_TRUNC('month', ordered_at)
            ) * 100, 1
        )
    END                                                 AS 前月比_pct
FROM orders
WHERE ordered_at >= '2024-01-01'
GROUP BY DATE_TRUNC('month', ordered_at)
ORDER BY 月;

-- これ 1本で：月次売上 / 累計 / 移動平均 / 前月比 を同時に出せる
-- 皆川くんが毎月 4〜5時間かけていた作業が、このクエリ 1本で完了する。

-- ============================================================
-- 【チャプター 01 チートシート】
-- ============================================================
--
-- ランキング:
--   ROW_NUMBER() OVER (ORDER BY 列 DESC)    -- 連番
--   RANK()       OVER (ORDER BY 列 DESC)    -- 同点同位、次飛ぶ
--   DENSE_RANK() OVER (ORDER BY 列 DESC)    -- 同点同位、次続く
--
-- PARTITION BY（カテゴリ内ランキングなど）:
--   RANK() OVER (PARTITION BY cat_id ORDER BY 売上 DESC)
--
-- 累計:
--   SUM(集計値) OVER (ORDER BY 月 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
--
-- 移動平均（直近 3行）:
--   AVG(集計値) OVER (ORDER BY 月 ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
--
-- 前月比:
--   LAG(値, 1) OVER (ORDER BY 月)   -- 1行前の値
--   LEAD(値, 1) OVER (ORDER BY 月)  -- 1行後の値
--
-- JSONB 基本:
--   col -> 'key'     -- JSON型で取得
--   col ->> 'key'    -- TEXT型で取得（比較・表示に）
--   col @> '{...}'   -- 包含検索（GINインデックスが効く）
--   col ? 'key'      -- キーの存在チェック
--
-- GINインデックス:
--   CREATE INDEX ON table USING GIN (jsonb_col);
--
-- 再帰CTE（WITH RECURSIVE）:
--   WITH RECURSIVE cte AS (
--       SELECT ... FROM t WHERE 起点条件   -- アンカー部
--       UNION ALL
--       SELECT ... FROM t JOIN cte ON 親子条件  -- 再帰部
--   )
--   SELECT * FROM cte;
--
-- UPSERT:
--   INSERT INTO t (cols) VALUES (vals)
--   ON CONFLICT (unique_col) DO NOTHING;           -- 重複無視
--   ON CONFLICT (unique_col) DO UPDATE SET col = EXCLUDED.col;  -- 上書き
--   ON CONFLICT (unique_col) DO UPDATE SET col = t.col + EXCLUDED.col;  -- 加算
--
-- ============================================================
