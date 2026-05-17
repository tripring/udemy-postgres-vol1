-- 遅いクエリを特定してEXPLAINで解析する
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- EXPLAIN はクエリの「実行計画」を表示するコマンドです。
-- PostgreSQLがどのようにデータを取得しようとしているかを確認できます。
--
-- EXPLAIN だけ         → 実際には実行せず、計画だけ表示（安全）
-- EXPLAIN ANALYZE      → 実際に実行して計画と実測値を両方表示
-- EXPLAIN (ANALYZE, BUFFERS) → さらにバッファ使用状況も表示（本格分析向け）


-- 3-1. まず遅いクエリを実行してみる（\timing で時間を確認）
-- ----------------------------------------------------------------
-- \timing を有効にしてからこのクエリを実行してください。
-- 5秒前後かかることが確認できれば問題の再現成功です。
--
-- このクエリは「2024年1月以降にdeliveredになった注文について
-- 顧客ごとの注文件数と合計購買額」を取得しています。
-- \timing
SELECT
    c.name,
    c.prefecture,
    COUNT(o.id)                      AS order_count,
    SUM(oi.quantity * oi.unit_price) AS total_spent
FROM customers c
JOIN orders o       ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id   = o.id
WHERE o.status     = 'delivered'
  AND o.ordered_at >= '2024-01-01'
GROUP BY c.id, c.name, c.prefecture
ORDER BY total_spent DESC
LIMIT 20;


-- 3-2. EXPLAIN で実行計画を確認する（実際には実行しない）
-- ----------------------------------------------------------------
-- 「Seq Scan on orders」が出ていれば30万件全件スキャンしています。
-- cost=0.00..XXXX の大きな数値が重い処理のサインです。
--
-- 読み方:
--   cost=起動コスト..総コスト  rows=予測行数  width=1行の平均バイト数
EXPLAIN
SELECT
    c.name,
    c.prefecture,
    COUNT(o.id)                      AS order_count,
    SUM(oi.quantity * oi.unit_price) AS total_spent
FROM customers c
JOIN orders o       ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id   = o.id
WHERE o.status     = 'delivered'
  AND o.ordered_at >= '2024-01-01'
GROUP BY c.id, c.name, c.prefecture
ORDER BY total_spent DESC
LIMIT 20;


-- 3-3. EXPLAIN ANALYZE で実際の実行時間を計測する
-- ----------------------------------------------------------------
-- BUFFERS オプションを加えると、何件のデータブロックを読んだかも確認できます。
-- shared hit  → キャッシュ（メモリ）から読んだブロック数
-- shared read → ディスクから読んだブロック数（多いと遅い）
--
-- ★ この出力と以下をセットで生成AIに貼ると改善アドバイスがもらえます:
--   1. このEXPLAIN ANALYZEの出力
--   2. 関連テーブルの定義（\d orders など）
--   3. 「このクエリを最適化するアドバイスをください」
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    c.name,
    c.prefecture,
    COUNT(o.id)                      AS order_count,
    SUM(oi.quantity * oi.unit_price) AS total_spent
FROM customers c
JOIN orders o       ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id   = o.id
WHERE o.status     = 'delivered'
  AND o.ordered_at >= '2024-01-01'
GROUP BY c.id, c.name, c.prefecture
ORDER BY total_spent DESC
LIMIT 20;
-- ↑ 「Seq Scan on orders」が表示されているはずです
--   actual time が大きい行が、ボトルネックになっている処理です


