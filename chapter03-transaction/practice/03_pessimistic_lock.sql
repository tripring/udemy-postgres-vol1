-- 悲観ロック（SELECT FOR UPDATE）
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- 考え方:「競合が起きると悲観的に想定し、取得時点でロックを取る」
-- SELECT FOR UPDATE は行を読み取ると同時に排他ロックをかける。
-- 他のセッションが同じ行を SELECT FOR UPDATE しようとするとブロックされる。
-- ============================================================

-- まず在庫を1に戻す
UPDATE inventory SET quantity = 1 WHERE product_id = 1;

-- ---- 3-1. SELECT FOR UPDATE の基本 -------------------------

BEGIN;

-- 在庫行を「ロックしながら」取得する
SELECT quantity
  FROM inventory
 WHERE product_id = 1
   FOR UPDATE;
-- → この時点で product_id=1 の行に排他ロックが掛かる
--   他のセッションは FOR UPDATE / UPDATE / DELETE を試みるとブロックされる

-- 在庫があれば減らす
UPDATE inventory
   SET quantity = quantity - 1
 WHERE product_id = 1;

COMMIT;
-- → COMMIT で初めてロックが解放される

-- ---- 3-2. 2セッションで試すとどうなるか -------------------
-- ターミナルA / B で以下の手順を試してください
--
-- 【ターミナルA】
-- BEGIN;
-- SELECT quantity FROM inventory WHERE product_id = 1 FOR UPDATE;
-- → 取得成功、ロック取得
--
-- 【ターミナルB】（ターミナルAがCOMMITするまで待ち続ける）
-- BEGIN;
-- SELECT quantity FROM inventory WHERE product_id = 1 FOR UPDATE;
-- → 「くるくる待ち」状態になる（ブロックされている）
--
-- 【ターミナルA】
-- UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;
-- COMMIT;
-- → ロック解放
--
-- 【ターミナルB がここで動き出す】
-- → quantity の値は既に 0 になっている
--   → アプリ側で「在庫0なので購入できません」と返せばよい

-- ---- 3-3. NOWAIT オプション（待たずにエラーにする） --------
-- ロックが取れなければ即座にエラーを返したい場合は NOWAIT を使う

BEGIN;
SELECT quantity
  FROM inventory
 WHERE product_id = 1
   FOR UPDATE NOWAIT;
-- → 他のセッションがロック中なら
--   ERROR: could not obtain lock on row in relation "inventory"
--   が即座に返る（ユーザーへ「混み合っています、再試行してください」と返せる）
ROLLBACK;

-- ---- 3-4. 在庫更新の安全な実装例（アプリで使うパターン） --

-- 在庫をリセット
UPDATE inventory SET quantity = 1 WHERE product_id = 1;

BEGIN;

-- 在庫をロックしながら取得
SELECT quantity
  FROM inventory
 WHERE product_id = 1
   FOR UPDATE;
-- → ここで quantity を確認し、1以上あれば購入可能と判断

-- 在庫を1減らし、注文を作成
UPDATE inventory
   SET quantity    = quantity - 1,
       updated_at  = NOW()
 WHERE product_id  = 1
   AND quantity   >= 1;   -- ← 念のためチェック条件も付ける
-- → 更新された行数が 0 ならば在庫なし扱いにする（GET DIAGNOSTICS で確認可）

INSERT INTO orders (customer_id, status, total_amount, ordered_at)
VALUES (1, 'confirmed', 12800.00, NOW());

INSERT INTO order_items (order_id, product_id, quantity, unit_price)
VALUES (currval('orders_id_seq'), 1, 1, 12800.00);

COMMIT;
-- → ここまで原子的に完了。他のセッションは SELECT FOR UPDATE でブロックされていたので
--   同じ在庫行を二重更新することはできない


