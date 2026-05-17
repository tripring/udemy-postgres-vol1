-- ロック調査と実運用テクニック
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- 本番で「クエリが遅い / 固まった」と報告が来たとき、
-- まずロック待ちを疑う。このセクションで調査手順を体得する。
-- ============================================================

-- ---- 6-1. ロック待ちを調べる --------------------------------
-- 現在どのセッションがどのセッションにブロックされているかを確認する。
-- 本番障害対応時に最初に実行すべきクエリ。

SELECT
    blocked.pid                       AS 待機PID,
    blocked.query                     AS 待機クエリ,
    now() - blocked.query_start       AS 待機時間,
    blocking.pid                      AS ブロッキングPID,
    blocking.query                    AS ブロッキングクエリ,
    blocking.state                    AS ブロッキング状態
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;

-- ---- 6-2. ロック待ちを手動で作って確認する -----------------
-- ターミナルAでロックを取り、ターミナルBで待機させてからこのクエリを実行する

-- 【ターミナルA で実行】
-- BEGIN;
-- UPDATE inventory SET quantity = quantity WHERE product_id = 1;
-- （COMMIT はまだしない）

-- 【ターミナルB で実行】
-- BEGIN;
-- UPDATE inventory SET quantity = quantity WHERE product_id = 1;
-- （ロック待ちになる）

-- 【別の監視用ターミナルで上記クエリを実行すると待機状況が見える】

-- ---- 6-3. idle in transaction の検出 -----------------------
-- BEGIN を発行したままクエリを実行せずに放置したセッションを検出する。
-- ロックを持ち続けるため他のクエリをブロックし続ける危険な状態。
--
-- 【悪化体験】
-- ターミナルAで次を実行し、COMMITせずに放置する。
--
--   BEGIN;
--   UPDATE inventory SET quantity = quantity WHERE product_id = 1;
--
-- そのままターミナルAで何もしないと、状態は idle in transaction になる。
-- この状態でもロックは残り、他のセッションを待たせ続ける。
--
-- ターミナルBで次を実行すると、ロック待ちになる。
--
--   UPDATE inventory SET quantity = quantity WHERE product_id = 1;
--
-- 監視用ターミナルで下のSQLを実行し、idle_duration を確認する。

SELECT
    pid,
    usename,
    state,
    now() - state_change    AS idle_duration,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY idle_duration DESC;

-- idle_duration が数分以上ある場合は pg_terminate_backend で切断を検討する
-- SELECT pg_terminate_backend(pid);  -- 切断するときは慎重に

-- ---- 6-4. ブロッキングセッションを強制終了する -------------
-- pg_cancel_backend: クエリを中断、接続は維持（エラーがアプリに返る）
-- pg_terminate_backend: セッションを切断、トランザクションはROLLBACKされる

-- ※ 実際に実行する場合は正しいPIDに置き換えること
-- SELECT pg_cancel_backend(12345);
-- SELECT pg_terminate_backend(12345);

-- ---- 6-5. SKIP LOCKED でジョブキューを実装する -------------
-- 複数ワーカーが同じキューから競合せずにジョブを取り出すパターン。
-- SKIP LOCKED: 他のワーカーがロック中のジョブをスキップして次のジョブを取得する。

-- まずジョブキューテーブルを作成する
CREATE TABLE IF NOT EXISTS job_queue (
    id         SERIAL PRIMARY KEY,
    payload    TEXT        NOT NULL,
    status     TEXT        NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- テストデータ投入
INSERT INTO job_queue (payload)
SELECT 'job_' || g FROM generate_series(1, 10) g
ON CONFLICT DO NOTHING;

-- 確認
SELECT * FROM job_queue ORDER BY id;

-- ワーカー1がジョブを1件取得するパターン（SKIP LOCKED あり）
BEGIN;
SELECT id, payload
  FROM job_queue
 WHERE status = 'pending'
 ORDER BY created_at
 LIMIT 1
   FOR UPDATE SKIP LOCKED;
-- → ロック中のジョブはスキップして次のジョブを即座に返す
--   複数ワーカーが同時実行してもブロックしない

ROLLBACK;  -- ここではロールバック（実際はUPDATE status='processing'してCOMMIT）

-- ---- 6-6. DDL のロックレベルを確認する ---------------------
-- ALTER TABLE は AccessExclusiveLock を取る（SELECT もブロックする）
-- どのくらい時間がかかるか・影響範囲を事前に把握することが重要

-- 以下のクエリで現在保持されているロックのモードを一覧できる
SELECT
    l.pid,
    l.mode,
    l.granted,
    c.relname
FROM pg_locks l
LEFT JOIN pg_class c ON c.oid = l.relation
WHERE l.relation IS NOT NULL
ORDER BY l.pid, c.relname;

-- nullable カラム追加（AccessExclusiveLock だが実質瞬間）
ALTER TABLE job_queue ADD COLUMN IF NOT EXISTS priority INTEGER DEFAULT 0;

-- 確認
\d job_queue

-- ---- 6-7. インデックスをオンラインで追加する ---------------
-- CREATE INDEX CONCURRENTLY: テーブルロックを最小化して安全にインデックスを追加
-- 通常の CREATE INDEX は ShareLock を取るため INSERT/UPDATE/DELETE をブロックする

-- 【悪化体験】通常の CREATE INDEX が書き込みを待たせる
--
-- 大きめの検証テーブルを作る。
DROP TABLE IF EXISTS index_lock_lab;

CREATE TABLE index_lock_lab AS
SELECT
    g AS id,
    (ARRAY['pending', 'confirmed', 'shipped', 'delivered', 'cancelled'])[(random() * 4 + 1)::INTEGER] AS status,
    NOW() - ((random() * 365)::INTEGER || ' days')::INTERVAL AS created_at,
    md5(g::TEXT) AS payload
FROM generate_series(1, 200000) AS g;

-- ターミナルA:
--   BEGIN;
--   CREATE INDEX idx_index_lock_lab_status ON index_lock_lab (status);
--   -- COMMITせずに止める
--
-- ターミナルB:
--   INSERT INTO index_lock_lab VALUES (999999, 'pending', NOW(), 'blocked?');
--   -- ターミナルAがCOMMIT/ROLLBACKするまで待たされる
--
-- 監視用ターミナル:
--   このファイル冒頭の 6-1 のSQLを実行し、ブロック関係を見る。
--
-- 後片付け:
--   ターミナルAで ROLLBACK;
--   ターミナルBの待機が解除されることを確認する。

-- 通常のインデックス作成（INSERT/UPDATE/DELETE をブロック）
-- CREATE INDEX idx_jq_status ON job_queue (status);

-- CONCURRENTLY を使えばほぼブロックなし（ただしトランザクション内では不可）
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_jq_status_created
    ON job_queue (status, created_at);

-- ---- 6-8. lock_timeout と statement_timeout の設定 --------
-- ロック待ちや長時間クエリを自動で止めるタイムアウト設定

-- 【ありがたみ体験】待ち続けるセッションと、5秒で失敗するセッションを比較する
--
-- ターミナルA:
--   BEGIN;
--   UPDATE inventory SET quantity = quantity WHERE product_id = 1;
--   -- COMMITせずにロックを保持
--
-- ターミナルB（タイムアウトなし）:
--   UPDATE inventory SET quantity = quantity WHERE product_id = 1;
--   -- ずっと待たされる
--
-- ターミナルBを Ctrl+C で止めたあと、今度は lock_timeout を設定する。
--
-- ターミナルB（タイムアウトあり）:
--   SET lock_timeout = '5s';
--   UPDATE inventory SET quantity = quantity WHERE product_id = 1;
--   -- 5秒後に ERROR: canceling statement due to lock timeout
--
-- 本番では、待ち続けて画面が固まるより、早く失敗してリトライやエラー表示に回す方が安全な場面がある。

-- セッションレベルで設定（この接続のみ有効）
SET lock_timeout = '5s';
SET statement_timeout = '30s';

-- 設定確認
SHOW lock_timeout;
SHOW statement_timeout;

-- セッションレベルの設定をリセット（デフォルトに戻す）
SET lock_timeout = 0;
SET statement_timeout = 0;

-- ロールに恒久的に設定する場合（接続するたびに自動適用）
-- ALTER ROLE udemart SET lock_timeout = '10s';
-- ALTER ROLE udemart SET statement_timeout = '60s';

-- 設定の確認
SELECT rolname, rolconfig
FROM pg_roles
WHERE rolname = 'udemart';

