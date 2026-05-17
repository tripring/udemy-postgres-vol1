-- パーティションテーブルの作成
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ------------------------------------------------------------
-- 2-1. パーティションテーブル（親テーブル）を作成する
--
-- PARTITION BY RANGE (ordered_at) で「注文日時」を分割キーに指定する。
-- 親テーブル自体はデータを持たず、ルーティングだけを担う。
--
-- 注意: PostgreSQL のパーティションテーブルでは
--       PRIMARY KEY にパーティションキーを含める必要がある。
--       → PRIMARY KEY (id, ordered_at) にしている理由がこれ。
-- ------------------------------------------------------------
DROP TABLE IF EXISTS orders_partitioned CASCADE;

CREATE TABLE orders_partitioned (
    id           SERIAL,
    customer_id  INTEGER      NOT NULL,
    status       VARCHAR(20)  NOT NULL DEFAULT 'pending',
    total_amount NUMERIC(12, 2),
    ordered_at   TIMESTAMP WITH TIME ZONE NOT NULL,
    shipped_at   TIMESTAMP WITH TIME ZONE,
    PRIMARY KEY (id, ordered_at)   -- パーティションキーを PK に含める
) PARTITION BY RANGE (ordered_at);


-- ------------------------------------------------------------
-- 2-2. 月単位のパーティションを作成する（2022年1月〜2024年12月）
--
-- FOR VALUES FROM ... TO ... の範囲は「左閉・右開」
--   FROM '2022-01-01' TO '2022-02-01'
--   = 2022-01-01 以上 かつ 2022-02-01 未満
--
-- 36ヶ月分を手書きするのは大変なので、DO ブロックで一括生成する。
-- ------------------------------------------------------------
DO $$
DECLARE
    y   INT;
    m   INT;
    ds  TEXT;   -- 開始日（例: '2022-01-01'）
    de  TEXT;   -- 終了日（例: '2022-02-01'）
    tbl TEXT;   -- テーブル名（例: orders_2022_01）
BEGIN
    FOR y IN 2022..2024 LOOP
        FOR m IN 1..12 LOOP
            -- パーティション名: orders_YYYY_MM
            tbl := format('orders_%s_%s', y, LPAD(m::TEXT, 2, '0'));
            -- 開始日・終了日
            ds  := format('%s-%s-01', y, LPAD(m::TEXT, 2, '0'));
            de  := (ds::DATE + INTERVAL '1 month')::DATE::TEXT;

            EXECUTE format(
                'CREATE TABLE %I PARTITION OF orders_partitioned '
                'FOR VALUES FROM (%L) TO (%L)',
                tbl, ds, de
            );
        END LOOP;
    END LOOP;
END;
$$;


-- ------------------------------------------------------------
-- 2-3. DEFAULT パーティションを作成する
--
-- 上記で定義した範囲（2022〜2024年）に収まらない行が入る受け皿。
-- DEFAULT パーティションがないと、範囲外の値を INSERT したときに
-- エラー "no partition of relation ... found for row" が発生する。
-- ------------------------------------------------------------
CREATE TABLE orders_default PARTITION OF orders_partitioned DEFAULT;


-- ------------------------------------------------------------
-- 2-4. パーティションテーブルへのインデックスを作成する
--
-- 親テーブルにインデックスを作成すると、すべての子パーティション
--（既存・将来追加するもの両方）に自動で同じインデックスが作られる。
-- ------------------------------------------------------------
CREATE INDEX idx_orders_partitioned_ordered_at ON orders_partitioned (ordered_at);
CREATE INDEX idx_orders_partitioned_customer_id ON orders_partitioned (customer_id);


-- ------------------------------------------------------------
-- 2-5. 作成されたパーティション一覧を確認する
--
-- pg_inherits: 親子関係（パーティション）の情報
-- pg_class: テーブル情報
-- ------------------------------------------------------------
SELECT
    parent.relname  AS parent_table,
    child.relname   AS partition_name
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child  ON pg_inherits.inhrelid  = child.oid
WHERE parent.relname = 'orders_partitioned'
ORDER BY child.relname;

