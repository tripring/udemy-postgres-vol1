-- 楽観ロック（version カラムによる競合検知）
-- ============================================================
-- 接続: bastion内で psql
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- 悲観ロックの問題点:
--   - ロック待ちが発生し、同時処理性能が下がる
--   - 長時間ロックを持ち続けるとデッドロックリスクが上がる
--
-- 楽観ロックの考え方:「競合はめったに起きない（楽観的）と仮定し、
--   取得時はロックせず、更新時に「自分が読んだ後に誰かが変更したか」を確認する」
-- ============================================================

-- ---- 4-1. version カラムを inventory に追加 ---------------

ALTER TABLE inventory ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

-- 現在の状態確認
SELECT product_id, quantity, version FROM inventory;

-- ---- 4-2. 楽観ロックの実装パターン ------------------------
-- 在庫をリセット
UPDATE inventory SET quantity = 1, version = 1 WHERE product_id = 1;

-- Step1: ロックなしで取得（高速）
SELECT product_id, quantity, version
  FROM inventory
 WHERE product_id = 1;
-- → quantity=1, version=1 を受け取る

-- Step2: 更新時に「version が変わっていないか」を WHERE 条件に含める
UPDATE inventory
   SET quantity   = quantity - 1,
       version    = version + 1,     -- バージョンをインクリメント
       updated_at = NOW()
 WHERE product_id = 1
   AND version    = 1;               -- ← 取得時と同じ version であることを確認！
-- → 更新できた行数を確認する（1行なら成功、0行なら競合負け）

-- 結果確認
SELECT product_id, quantity, version FROM inventory WHERE product_id = 1;
-- → quantity=0, version=2

-- ---- 4-3. 競合した場合のシミュレーション ------------------
-- 在庫をリセット
UPDATE inventory SET quantity = 1, version = 1 WHERE product_id = 1;

-- 「顧客Aさんと顧客Bさんがほぼ同時に version=1 の在庫を読んだ」状態を想定

-- 顧客Aさんが先に UPDATE
UPDATE inventory
   SET quantity   = quantity - 1,
       version    = version + 1,
       updated_at = NOW()
 WHERE product_id = 1
   AND version    = 1;
-- → 1行更新成功。version は 2 になった

-- 顧客Bさんが少し遅れて UPDATE（version=1 で試みる）
UPDATE inventory
   SET quantity   = quantity - 1,
       version    = version + 1,
       updated_at = NOW()
 WHERE product_id = 1
   AND version    = 1;              -- ← すでに version=2 なのでマッチしない！
-- → 0行更新。アプリはこれを受け取り「競合が発生したため再試行してください」と返す

-- 最終状態の確認（quantity=0、version=2 のまま）
SELECT product_id, quantity, version FROM inventory WHERE product_id = 1;


