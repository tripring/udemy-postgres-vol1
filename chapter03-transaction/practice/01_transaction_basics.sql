-- トランザクションの基本（BEGIN / COMMIT / ROLLBACK）
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- ---- 1-1. BEGIN〜COMMIT: 変更を確定する ----------------------

BEGIN;

-- 在庫を確認
SELECT product_id, quantity FROM inventory WHERE product_id = 1;

-- 在庫を1つ減らす
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;

-- 変更後の値を確認（このセッション内では反映されている）
SELECT product_id, quantity FROM inventory WHERE product_id = 1;

-- 問題なければ確定
COMMIT;

-- COMMIT後の確認（quantity が 0 になっているはず）
SELECT product_id, quantity FROM inventory WHERE product_id = 1;


-- ---- 1-2. BEGIN〜ROLLBACK: 変更を取り消す -------------------

-- まず在庫をリセットしておく
UPDATE inventory SET quantity = 1 WHERE product_id = 1;

BEGIN;

-- 在庫を減らす
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;

-- 変更後の値を確認（0 になっている）
SELECT product_id, quantity FROM inventory WHERE product_id = 1;

-- やっぱり取り消す！
ROLLBACK;

-- ROLLBACK後の確認（quantity が 1 に戻っているはず）
SELECT product_id, quantity FROM inventory WHERE product_id = 1;


-- ---- 1-3. エラー時の自動ロールバック -----------------------

BEGIN;

UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;

-- 存在しないカラムを参照してエラーを起こす
-- SELECT no_such_column FROM inventory;
-- → エラーが発生するとトランザクションは「アボート状態」になる
--   この後のSQL（COMMITも含む）はすべて無効になり、
--   ROLLBACK でしか抜け出せない

ROLLBACK;


