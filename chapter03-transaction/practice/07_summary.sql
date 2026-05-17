-- まとめ確認クエリ
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- 現在の在庫状態
-- ※ version 列は 04_optimistic_lock.sql を実行した場合のみ存在します
SELECT
    p.id            AS 商品ID,
    p.name          AS 商品名,
    i.quantity      AS 在庫数,
    i.updated_at    AS 最終更新
FROM inventory i
JOIN products p ON p.id = i.product_id
ORDER BY p.id;

-- 注文一覧
SELECT
    o.id            AS 注文ID,
    c.name          AS 顧客名,
    o.status        AS ステータス,
    o.total_amount  AS 合計金額,
    o.ordered_at    AS 注文日時
FROM orders o
JOIN customers c ON c.id = o.customer_id
ORDER BY o.id;
