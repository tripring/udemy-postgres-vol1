-- マテリアライズドビューで集計を高速化する
-- ============================================================
-- 接続: bastion内で psql
-- 実行例: psql -f ~/udemy-postgres-vol1/chapter02-tuning/practice/05_materialized_view.sql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- UdeMartの経営ダッシュボードでは、日次売上グラフが何度も参照されます。
-- そのたびに30万件の注文をGROUP BYしていたら、DBは同じ仕事を繰り返します。
--
-- 「昨日までの売上推移」が見られればよく、秒単位の最新性が不要なら、
-- マテリアライズドビューで集計結果を保存しておく判断ができます。
--
-- 毎回同じ重い集計クエリを実行している場合は、マテリアライズドビューが有効です。
-- 集計結果をDBに物理的に保存することで、参照時は保存済み結果を読むだけになります。
--
-- 通常のVIEW   → 参照するたびに内部でSELECTを実行（毎回計算）
-- マテリアライズドビュー → 結果をディスクに保存（参照時は高速・REFRESHで更新）

DROP VIEW IF EXISTS v_daily_sales;
DROP MATERIALIZED VIEW IF EXISTS mv_daily_sales;

-- 5-1. 毎回集計すると遅い日次売上レポートクエリ
-- ----------------------------------------------------------------
-- このクエリを経営ダッシュボードが毎分実行していたとしたら、
-- 30万件の注文テーブルを毎分フルスキャンすることになります。
-- \timing で実行時間を計測してみましょう。
SELECT
    DATE(ordered_at)      AS sale_date,
    COUNT(*)              AS order_count,
    SUM(total_amount)     AS total_sales,
    AVG(total_amount)     AS avg_order_amount
FROM orders
WHERE status != 'cancelled'
GROUP BY DATE(ordered_at)
ORDER BY sale_date DESC;


-- 5-2. マテリアライズドビューとして結果を保存する
-- ----------------------------------------------------------------
-- CREATE MATERIALIZED VIEW を実行すると:
-- 1. SELECT を1回実行して結果を計算する
-- 2. 結果をディスクに保存する（物理テーブルと同じイメージ）
-- 3. 次回から SELECT * FROM mv_daily_sales は保存済みデータを返す
CREATE MATERIALIZED VIEW mv_daily_sales AS
SELECT
    DATE(ordered_at)                    AS sale_date,
    COUNT(*)                            AS order_count,
    SUM(total_amount)                   AS total_sales,
    AVG(total_amount)::NUMERIC(12, 2)   AS avg_order_amount
FROM orders
WHERE status != 'cancelled'
GROUP BY DATE(ordered_at)
ORDER BY sale_date DESC;


-- 5-3. ユニークインデックスを追加する
-- ----------------------------------------------------------------
-- REFRESH MATERIALIZED VIEW CONCURRENTLY を使うために必須です。
-- CONCURRENTLYはリフレッシュ中も参照をブロックしない本番向けオプションですが、
-- ユニークインデックスがないと使えません。
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_daily_sales_sale_date
    ON mv_daily_sales (sale_date);


-- 5-4. マテリアライズドビューから読む（高速）
-- ----------------------------------------------------------------
-- 同じ日次売上データですが、保存済みの結果を読むだけなので
-- 5-1 より大幅に速くなっているはずです。\timing で比較してみましょう。
SELECT * FROM mv_daily_sales ORDER BY sale_date DESC LIMIT 10;


-- 5-5. データが更新されたらリフレッシュする
-- ----------------------------------------------------------------
-- 新しい注文が入ってもマテリアライズドビューは自動更新されません。
-- REFRESH コマンドで明示的に最新化する必要があります。
--
-- CONCURRENTLY なし → リフレッシュ中は参照がブロックされる（排他ロック）
-- CONCURRENTLY あり → リフレッシュ中も参照可能（本番環境での推奨）
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;


-- 5-6. 通常のVIEWとの比較
-- ----------------------------------------------------------------
-- 通常のVIEWを作成して、EXPLAIN で違いを確認します。
-- VIEWはクエリの「別名」にすぎないため、参照するたびに全件スキャンが走ります。
CREATE VIEW v_daily_sales AS
SELECT
    DATE(ordered_at)  AS sale_date,
    COUNT(*)          AS order_count,
    SUM(total_amount) AS total_sales
FROM orders
WHERE status != 'cancelled'
GROUP BY DATE(ordered_at);

-- 通常のVIEWはEXPLAINしてみると内部でSeq Scanが走っていることがわかる
-- → 参照するたびに orders テーブルを全件スキャンする
EXPLAIN SELECT * FROM v_daily_sales ORDER BY sale_date DESC LIMIT 10;

-- マテリアライズドビューはSeq Scanでも元データではなくビュー自体（保存済みデータ）をスキャンする
-- → スキャン対象が orders（30万行）ではなく mv_daily_sales（約730行）になる
EXPLAIN SELECT * FROM mv_daily_sales ORDER BY sale_date DESC LIMIT 10;
