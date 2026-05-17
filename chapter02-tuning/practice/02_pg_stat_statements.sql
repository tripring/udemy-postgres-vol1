-- 過去のスロークエリを調べる (pg_stat_statements)
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- pg_stat_statements は過去に実行されたすべてのクエリの統計情報を
-- 蓄積する拡張機能です。「この1週間で一番重かったクエリはどれか」を
-- 調べるのに非常に有用です。setup.sql で拡張を有効化済みです。


-- 2-1. 平均実行時間が長いクエリ TOP10
-- ----------------------------------------------------------------
-- mean_exec_time でソートすることで「1回あたりが重いクエリ」を特定できます。
-- バッチ処理や複雑なレポートクエリがここに出てくることが多いです。
--
-- カラムの読み方:
--   calls          → このクエリが何回実行されたか
--   mean_ms        → 1回あたりの平均実行時間（ミリ秒）
--   total_ms       → 累計実行時間（ミリ秒）
--   rows           → 返した（または影響を与えた）行の累計
--   query_snippet  → クエリの先頭100文字
SELECT
    calls,
    round(mean_exec_time::NUMERIC, 2) AS mean_ms,
    round(total_exec_time::NUMERIC, 2) AS total_ms,
    rows,
    left(query, 100) AS query_snippet
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;


-- 2-2. 総実行時間が長いクエリ TOP10（DBへの累積負荷が大きいクエリ）
-- ----------------------------------------------------------------
-- total_exec_time でソートすることで「DBに最も負荷をかけているクエリ」を
-- 特定できます。1回は軽くても頻繁に呼ばれるクエリがここに出てきます。
-- アプリのホット（頻繁に呼ばれる）クエリを特定したいときに使います。
SELECT
    calls,
    round(mean_exec_time::NUMERIC, 2) AS mean_ms,
    round(total_exec_time::NUMERIC, 2) AS total_ms,
    rows,
    left(query, 100) AS query_snippet
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;


-- 2-3. 統計をリセットする（必要に応じて実行）
-- ----------------------------------------------------------------
-- チューニング作業の前後で比較したいとき、または統計が古くなったときに
-- 使います。本番環境でうっかり実行しないよう注意してください。
-- SELECT pg_stat_statements_reset();


