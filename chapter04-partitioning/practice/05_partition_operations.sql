-- 運用（パーティション追加・削除）
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ------------------------------------------------------------
-- 5-1. 新しい月のパーティションを追加する
--
-- 2025年1月が始まる前に追加しておく。
-- このパーティションが存在しない状態で 2025-01 の注文が来ると
-- DEFAULT パーティションに入ってしまう。
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS orders_2025_01 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

-- 追加されたことを確認
SELECT relname
FROM pg_class
WHERE relname = 'orders_2025_01';


-- ------------------------------------------------------------
-- 5-2. テスト: 2025年1月のデータが正しいパーティションに入るか確認
-- ------------------------------------------------------------
INSERT INTO orders_partitioned (customer_id, status, total_amount, ordered_at)
VALUES (1, 'confirmed', 50000.00, '2025-01-15 12:00:00+09');

-- orders_2025_01 に 1 件入っているはず
SELECT count(*) AS count_in_jan_2025 FROM orders_2025_01;

-- テスト用データを削除（必要であれば）
DELETE FROM orders_partitioned
WHERE ordered_at >= '2025-01-01' AND ordered_at < '2025-02-01';


-- ------------------------------------------------------------
-- 5-3. 古いパーティションをデタッチする（アーカイブ）
--
-- DETACH PARTITION は物理削除しない。
-- デタッチ後は orders_2022_01 が独立したテーブルとして残る。
-- orders_partitioned に対する SELECT/INSERT には影響しない。
-- ------------------------------------------------------------

-- デタッチ前: orders_partitioned に orders_2022_01 が含まれている
SELECT count(*) AS before_detach FROM orders_partitioned
WHERE ordered_at >= '2022-01-01' AND ordered_at < '2022-02-01';

-- デタッチ実行
ALTER TABLE orders_partitioned DETACH PARTITION orders_2022_01;

-- デタッチ後: orders_partitioned から 2022年1月分が見えなくなる
SELECT count(*) AS after_detach FROM orders_partitioned
WHERE ordered_at >= '2022-01-01' AND ordered_at < '2022-02-01';

-- デタッチしたテーブルは独立テーブルとして直接参照できる
SELECT count(*) AS archived_rows FROM orders_2022_01;


-- ------------------------------------------------------------
-- 5-4. デタッチしたパーティションを親テーブルに再アタッチする
--
-- アーカイブをやり直したい場合などに使う。
-- FROM/TO の範囲は元の定義と一致させる必要がある。
-- ------------------------------------------------------------
ALTER TABLE orders_partitioned ATTACH PARTITION orders_2022_01
    FOR VALUES FROM ('2022-01-01') TO ('2022-02-01');

-- 再アタッチ後: 2022年1月分が再び見える
SELECT count(*) AS reattached_rows FROM orders_partitioned
WHERE ordered_at >= '2022-01-01' AND ordered_at < '2022-02-01';


-- ------------------------------------------------------------
-- 5-5. （参考）古いパーティションを完全に削除する
--
-- アーカイブも不要になったら DROP TABLE で削除する。
-- まずデタッチしてから DROP するのが安全な手順。
-- ------------------------------------------------------------
-- ALTER TABLE orders_partitioned DETACH PARTITION orders_2022_01;
-- DROP TABLE orders_2022_01;


-- ------------------------------------------------------------
-- 5-6. （参考）PostgreSQL 14 以降: CONCURRENTLY で無停止デタッチ
--
-- 通常の DETACH は親テーブルに ACCESS EXCLUSIVE ロックをかけるため
-- 本番環境では業務が止まるリスクがある。
-- CONCURRENTLY を使うとロックを最小限に抑えて切り離せる。
-- ただし、完了まで時間がかかる場合がある。
-- ------------------------------------------------------------
-- ALTER TABLE orders_partitioned DETACH PARTITION orders_2022_02 CONCURRENTLY;


-- ============================================================
-- 最終確認: パーティション構成の全体像を見る
-- ============================================================
SELECT
    parent.relname                                  AS parent_table,
    child.relname                                   AS partition_name,
    pg_get_expr(child.relpartbound, child.oid, true) AS partition_range,
    pg_size_pretty(pg_relation_size(child.oid))     AS size
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child  ON pg_inherits.inhrelid  = child.oid
WHERE parent.relname = 'orders_partitioned'
ORDER BY child.relname;
