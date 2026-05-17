-- 使われていないインデックスを発見する
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- インデックスはINSERT/UPDATE/DELETEのたびに更新コストが発生します。
-- 使われていないインデックスは「書き込みを遅くするだけの重荷」です。


-- 8-1. 使われていないインデックス（idx_scan = 0）を探す
-- ----------------------------------------------------------------
-- ★ サーバー再起動や pg_stat_reset() で統計がリセットされるため
--   十分な期間（最低1〜2週間）稼働した後で確認するのがベストです。
SELECT
    schemaname,
    relname                                            AS table_name,
    indexrelname                                       AS index_name,
    idx_scan                                           AS times_used,
    pg_size_pretty(pg_relation_size(indexrelid))       AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;


-- 8-2. 使用頻度と書き込みコストを比較する
-- ----------------------------------------------------------------
-- read_uses（読み取りで使われた回数）が少なく
-- write_ops（書き込み更新回数）が多いインデックスはコスト割れしている
SELECT
    i.relname                                          AS index_name,
    s.idx_scan                                         AS read_uses,
    pg_size_pretty(pg_relation_size(i.oid))            AS index_size,
    t.n_tup_ins + t.n_tup_upd + t.n_tup_del           AS write_ops
FROM pg_stat_user_indexes s
JOIN pg_class i           ON i.oid      = s.indexrelid
JOIN pg_stat_user_tables t ON t.relid   = s.relid
WHERE s.schemaname = 'public'
ORDER BY s.idx_scan ASC, write_ops DESC
LIMIT 20;


-- 8-3. 重複インデックスを探す
-- ----------------------------------------------------------------
-- (a, b) のインデックスがあるとき、(a) 単独のインデックスは冗長です。
-- 複合インデックスの先頭列は単独インデックスの代替になります。
SELECT
    indrelid::regclass  AS table_name,
    array_agg(indexrelid::regclass ORDER BY indexrelid) AS indexes,
    array_agg(indkey ORDER BY indexrelid) AS index_columns
FROM pg_index
GROUP BY indrelid, indkey
HAVING count(*) > 1;  -- 同じカラム構成のインデックスが複数あるもの

