-- デッドロック
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- デッドロックとは:
--   セッションAが「リソースX」を持ちながら「リソースY」を待ち、
--   セッションBが「リソースY」を持ちながら「リソースX」を待つ状態。
--   互いに永遠に待ち続けるため、PostgreSQL が検知して一方を強制 ROLLBACK する。
-- ============================================================

-- ---- 5-1. デッドロックの再現 --------------------------------
-- 2つのターミナルで以下を順に実行してください
--
-- 【ターミナルA】
-- BEGIN;
-- UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;
-- → product_id=1 の行をロック
--
-- 【ターミナルB】
-- BEGIN;
-- UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 2;
-- → product_id=2 の行をロック
--
-- 【ターミナルA】（ここでBがロックしている行を取りに行く）
-- UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 2;
-- → ターミナルBがロック中なので待ち状態になる
--
-- 【ターミナルB】（ここでAがロックしている行を取りに行く）
-- UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;
-- → ターミナルAもロック中 → デッドロック発生！
--   PostgreSQLが検知してどちらか一方に以下のエラーを返す:
--   ERROR: deadlock detected
--   DETAIL: Process XXXX waits for ShareLock on transaction YYYY;
--           blocked by process ZZZZ.
-- → エラーになったセッションは自動的に ROLLBACK される
-- → もう一方のセッションは正常に続行・COMMIT できる

-- ---- 5-2. デッドロックを防ぐコツ: 取得順序を統一する ------
-- NG: 複数行を更新するとき、セッションごとに取得順序がバラバラ
--   セッションA: product_id=1 → product_id=2 の順でロック
--   セッションB: product_id=2 → product_id=1 の順でロック  ← 逆！

-- OK: 必ず小さいIDから順にロックする（順序を統一）
BEGIN;
SELECT quantity FROM inventory WHERE product_id IN (1, 2) ORDER BY product_id FOR UPDATE;
-- → product_id の昇順でロックが取得されるため、
--   どのセッションも同じ順序でロックを取りに行き、デッドロックが起きない
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 2;
ROLLBACK; -- ここでは確定せず元に戻す


-- ---- 5-3. pg_locks でロック状態を確認する ------------------
-- 現在発生しているロックの一覧を確認できる（別ターミナルから監視に使う）
SELECT
    l.pid,
    l.relation::regclass   AS table_name,
    l.mode,
    l.granted,
    a.query
FROM pg_locks    l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.relation IS NOT NULL
  AND l.relation::regclass::text LIKE '%inventory%'
ORDER BY l.pid;

-- ---- 5-4. ブロックの原因を調べる ---------------------------
-- あるセッションが何を待っているか、誰にブロックされているかを確認
SELECT
    blocked.pid                            AS blocked_pid,
    blocked.query                          AS blocked_query,
    blocking.pid                           AS blocking_pid,
    blocking.query                         AS blocking_query
FROM pg_stat_activity     blocked
JOIN pg_stat_activity     blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;


