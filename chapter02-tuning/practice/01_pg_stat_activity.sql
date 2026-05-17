-- 実行中のクエリを調べる
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- pg_stat_activity はPostgreSQLに接続中のすべてのセッションと
-- 実行中クエリをリアルタイムで確認できるシステムビューです。
-- サーバーの"今"の状態を把握するための第一歩です。


-- 1-1. 実行中の全クエリを確認する
-- ----------------------------------------------------------------
-- state が 'active'  → 今まさにクエリを実行中
-- state が 'idle'    → 接続は張ってあるが何もしていない
-- state が 'idle in transaction' → トランザクションを開いたまま放置（要注意）
-- pg_stat_activity 自身を参照するクエリはノイズになるので除外しています
SELECT
    pid,
    usename,
    state,
    now() - query_start AS duration,
    left(query, 80)     AS query_snippet
FROM pg_stat_activity
WHERE state != 'idle'
  AND query NOT ILIKE '%pg_stat_activity%'
ORDER BY duration DESC NULLS LAST;


-- 1-2. 1秒以上かかっているクエリのみ表示
-- ----------------------------------------------------------------
-- (now() - query_start) で「クエリ開始からの経過時間」を計算します。
-- 1秒を超えるものだけ抽出することでスロークエリを見つけられます。
-- 本番監視では INTERVAL '5 second' や '30 second' に調整することもあります。
SELECT
    pid,
    now() - query_start AS duration,
    state,
    query
FROM pg_stat_activity
WHERE (now() - query_start) > INTERVAL '1 second'
  AND state = 'active'
ORDER BY duration DESC;


