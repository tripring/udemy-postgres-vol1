-- インデックスを貼りすぎると書き込みはどれくらい遅くなるか
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- 参考書ではよく「インデックスを貼りすぎると遅くなる」と説明されます。
-- しかし実務で必要なのは、次の2つを自分で判断できることです。
--
--   1. インデックスを増やすと INSERT / UPDATE がどれくらい劣化するのか
--   2. これ以上インデックスを増やしてはいけない、とどこで判断するのか
--
-- この実習では、同じ50,000件のINSERTと一部UPDATEを、
-- 追加インデックス0本 / 1本 / 3本 / 6本 の状態で実行し、劣化率を測ります。
-- id のPRIMARY KEYインデックスは常に存在するため、ここでは追加インデックス数で比較します。
--
-- 注意:
--   実行環境のCPU、Docker設定、キャッシュ状態で数値は変わります。
--   絶対値ではなく「比率」を見てください。

DROP TABLE IF EXISTS index_cost_lab;

CREATE TEMP TABLE index_cost_results (
    label        TEXT,
    index_count  INTEGER,
    insert_ms    NUMERIC,
    update_ms    NUMERIC,
    table_size   TEXT,
    index_size   TEXT
);

CREATE OR REPLACE FUNCTION run_index_cost_lab(
    p_label TEXT,
    p_index_sql TEXT[]
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql       TEXT;
    v_started   TIMESTAMPTZ;
    v_insert_ms NUMERIC;
    v_update_ms NUMERIC;
    v_index_size BIGINT;
BEGIN
    DROP TABLE IF EXISTS index_cost_lab;

    CREATE TABLE index_cost_lab (
        id           BIGSERIAL PRIMARY KEY,
        customer_id  INTEGER NOT NULL,
        status       TEXT NOT NULL,
        ordered_at   TIMESTAMP NOT NULL,
        total_amount NUMERIC(12, 2) NOT NULL,
        prefecture   TEXT NOT NULL,
        email        TEXT NOT NULL
    );

    FOREACH v_sql IN ARRAY p_index_sql LOOP
        EXECUTE v_sql;
    END LOOP;

    v_started := clock_timestamp();

    INSERT INTO index_cost_lab (customer_id, status, ordered_at, total_amount, prefecture, email)
    SELECT
        ((random() * 99999) + 1)::INTEGER,
        (ARRAY['pending', 'confirmed', 'shipped', 'delivered', 'cancelled'])[(random() * 4 + 1)::INTEGER],
        NOW() - ((random() * 730)::INTEGER || ' days')::INTERVAL,
        ((random() * 50000) + 100)::NUMERIC(12, 2),
        (ARRAY['東京都', '大阪府', '神奈川県', '愛知県', '北海道', '福岡県'])[(random() * 5 + 1)::INTEGER],
        'user_' || g || '@example.com'
    FROM generate_series(1, 50000) AS g;

    v_insert_ms := EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000;

    v_started := clock_timestamp();

    UPDATE index_cost_lab
       SET status = CASE WHEN status = 'pending' THEN 'confirmed' ELSE 'pending' END,
           total_amount = total_amount + 1
     WHERE id % 5 = 0;

    v_update_ms := EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000;

    SELECT COALESCE(SUM(pg_relation_size(indexname::regclass)), 0)
      INTO v_index_size
      FROM pg_indexes
     WHERE schemaname = 'public'
       AND tablename = 'index_cost_lab';

    INSERT INTO index_cost_results (label, index_count, insert_ms, update_ms, table_size, index_size)
    VALUES (
        p_label,
        COALESCE(array_length(p_index_sql, 1), 0),
        v_insert_ms,
        v_update_ms,
        pg_size_pretty(pg_relation_size('index_cost_lab')),
        pg_size_pretty(v_index_size)
    );
END;
$$;

-- 13-1. 追加インデックスなし
-- ----------------------------------------------------------------
SELECT run_index_cost_lab('追加0本: 追加インデックスなし', ARRAY[]::TEXT[]);

-- 13-2. よく使う検索条件に1本だけ貼る
-- ----------------------------------------------------------------
SELECT run_index_cost_lab('追加1本: customer_id', ARRAY[
    'CREATE INDEX idx_index_cost_lab_customer_id ON index_cost_lab (customer_id)'
]);

-- 13-3. 画面要件が増えて3本にする
-- ----------------------------------------------------------------
SELECT run_index_cost_lab('追加3本: 一覧・日付検索向け', ARRAY[
    'CREATE INDEX idx_index_cost_lab_customer_id ON index_cost_lab (customer_id)',
    'CREATE INDEX idx_index_cost_lab_status_ordered_at ON index_cost_lab (status, ordered_at DESC)',
    'CREATE INDEX idx_index_cost_lab_ordered_at ON index_cost_lab (ordered_at DESC)'
]);

-- 13-4. 「念のため」で6本に増やす
-- ----------------------------------------------------------------
SELECT run_index_cost_lab('追加6本: 念のためが増えた状態', ARRAY[
    'CREATE INDEX idx_index_cost_lab_customer_id ON index_cost_lab (customer_id)',
    'CREATE INDEX idx_index_cost_lab_status_ordered_at ON index_cost_lab (status, ordered_at DESC)',
    'CREATE INDEX idx_index_cost_lab_ordered_at ON index_cost_lab (ordered_at DESC)',
    'CREATE INDEX idx_index_cost_lab_email_lower ON index_cost_lab (LOWER(email))',
    'CREATE INDEX idx_index_cost_lab_total_amount ON index_cost_lab (total_amount)',
    'CREATE INDEX idx_index_cost_lab_prefecture_status ON index_cost_lab (prefecture, status)'
]);

-- 13-5. 結果を見る
-- ----------------------------------------------------------------
-- insert_ratio / update_ratio は、追加インデックスなしを1.00とした劣化率です。
-- 例: 2.50 なら「2.5倍遅い」という意味です。
WITH base AS (
    SELECT insert_ms, update_ms
    FROM index_cost_results
    WHERE index_count = 0
)
SELECT
    r.label,
    r.index_count,
    ROUND(r.insert_ms, 1) AS insert_ms,
    ROUND(r.insert_ms / b.insert_ms, 2) AS insert_ratio,
    ROUND(r.update_ms, 1) AS update_ms,
    ROUND(r.update_ms / b.update_ms, 2) AS update_ratio,
    r.table_size,
    r.index_size
FROM index_cost_results r
CROSS JOIN base b
ORDER BY r.index_count;

-- 13-6. 判断の練習
-- ----------------------------------------------------------------
-- 次の問いに答えてください。
--
-- Q1. 1本、3本、6本で INSERT は何倍遅くなりましたか？
-- Q2. UPDATE は INSERT より劣化しやすいですか？それはなぜですか？
-- Q3. 6本のインデックスのうち、実際に必要だと説明できるものはいくつありますか？
-- Q4. 読み取りが10倍速くなるなら、書き込み1.3倍は許容できますか？
-- Q5. 読み取りがほとんど速くならないなら、書き込み1.3倍は許容できますか？
--
-- 実務での結論:
--   インデックス本数だけで判断しない。
--   読み取り改善量、書き込み劣化率、使用頻度、SLO、ストレージをセットで判断する。

DROP FUNCTION IF EXISTS run_index_cost_lab(TEXT, TEXT[]);
