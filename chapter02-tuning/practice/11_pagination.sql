-- OFFSETの罠とキーセット方式
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 11-1. OFFSET のコストを EXPLAIN ANALYZE で確認 --------

-- ordered_at のインデックスを作成しておく
CREATE INDEX IF NOT EXISTS idx_orders_ordered_at_desc
    ON orders (ordered_at DESC, id DESC);

-- 1ページ目（速い）
EXPLAIN ANALYZE
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC, id DESC
LIMIT 20 OFFSET 0;

-- 5,000ページ目（遅い：100,000行読み捨て）
EXPLAIN ANALYZE
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC, id DESC
LIMIT 20 OFFSET 100000;

-- 確認ポイント:
--   2つの実行計画を比べると、OFFSET が大きいほど
--   "rows removed by filter" や fetch コストが増えていることが確認できる。

-- ---- 11-2. キーセット方式（カーソルページネーション）------

-- STEP 1: 初回（1ページ目）
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC, id DESC
LIMIT 20;

-- → 最後の行の (ordered_at, id) をメモする（例: '2024-12-28 22:11:05', 24001）

-- STEP 2: 次ページ（前ページ末尾の値を WHERE に使う）
-- ※ STEP 1 の最終行の ordered_at と id を WHERE に直接書く
--   ↓ 実際の値はSTEP 1の結果を見て書き換えること（例）
SELECT id, ordered_at, total_amount
FROM orders
WHERE ordered_at < (NOW() - INTERVAL '180 days')
ORDER BY ordered_at DESC, id DESC
LIMIT 20;

-- 本番アプリでの実装イメージ:
--   WHERE (ordered_at, id) < (:last_ordered_at, :last_id)
--   (:last_ordered_at, :last_id) はアプリ側で前ページ末尾の値を保持して渡す。
--   サブクエリもOFFSETも不要になる。

-- ---- 11-3. どちらの方式が速いか EXPLAIN で比較 ------------
-- キーセット方式の真価は「カーソル値をアプリ側で保持する」ことで発揮される。
-- ここでは実行計画の違いを Index Scan / Sort で確認する。

-- OFFSET 方式: ページが深いほどコスト増（前ページまで全件読む）
EXPLAIN ANALYZE
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC, id DESC
LIMIT 20 OFFSET 50000;

-- キーセット方式: WHERE 条件 + インデックスで直接その位置に飛ぶ
-- （ordered_at の値はデータ範囲の中間付近を指定。実際にはアプリが保持する値）
EXPLAIN ANALYZE
SELECT id, ordered_at, total_amount
FROM orders
WHERE ordered_at < (NOW() - INTERVAL '365 days')
ORDER BY ordered_at DESC, id DESC
LIMIT 20;

-- 確認ポイント:
--   OFFSET 方式 → rows removed by filter が大きい（読み捨てが多い）
--   キーセット方式 → Index Scan だけで済み、Rows Removed が少ない

-- ---- 11-4. ページネーション比較まとめ ----------------------
-- OFFSET 方式:   ページが深くなるほど遅くなる（O(n)）
-- キーセット方式: インデックスが使われ、どのページも同速（O(log n)）
--
-- 使い分け:
--   OFFSET    → ページ数が少ない / 任意ページへ直接ジャンプが必要
--   キーセット → APIの無限スクロール / 大量データの逐次取得


-- ============================================================
-- 後片付け（学習後に必要であれば実行）
-- ============================================================
-- 作成したオブジェクトをまとめて削除する場合はこちら
--
-- DROP INDEX IF EXISTS idx_orders_status_ordered_at;
-- DROP INDEX IF EXISTS idx_order_items_order_id;
-- DROP MATERIALIZED VIEW IF EXISTS mv_daily_sales;
-- DROP VIEW IF EXISTS v_daily_sales;
