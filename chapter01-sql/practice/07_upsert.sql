-- UPSERT（INSERT ... ON CONFLICT）
-- ============================================================
-- 接続: psql -h localhost -U udemart -d udemart
-- 事前準備: setup.sql を先に実行してください
-- ============================================================

-- 「存在すれば更新、なければ挿入」を 1文で原子的に実行する。
-- SELECT → INSERT or UPDATE の 2ステップより安全で高速。
-- ============================================================

-- ---- 7-1. ON CONFLICT DO NOTHING（重複は無視）-----------
-- 在庫レコードが存在しなければ挿入、存在すれば何もしない

-- まず現状を確認
SELECT product_id, quantity FROM inventory WHERE product_id IN (1, 2, 999);

-- product_id=1 はすでに存在する → DO NOTHING で無視される
INSERT INTO inventory (product_id, quantity)
VALUES (1, 999)
ON CONFLICT (product_id) DO NOTHING;

SELECT product_id, quantity FROM inventory WHERE product_id = 1;
-- → quantity は変わっていない（DO NOTHINGが効いた）

-- ---- 7-2. ON CONFLICT DO UPDATE（UPSERT）---------------
-- 存在すれば量を加算、存在しなければ新規挿入する

-- EXCLUDED は「挿入しようとした行」を指す疑似テーブル
INSERT INTO inventory (product_id, quantity)
VALUES (1, 50)
ON CONFLICT (product_id)
DO UPDATE SET
    quantity   = inventory.quantity + EXCLUDED.quantity,
    updated_at = NOW();

SELECT product_id, quantity, updated_at
FROM inventory WHERE product_id = 1;
-- → quantity が 50 加算されている

-- ---- 7-3. 最新値で上書きするパターン ----------------------
-- 外部システムからの定期同期（常に最新値に上書き）

INSERT INTO inventory (product_id, quantity, updated_at)
VALUES (1, 100, NOW())
ON CONFLICT (product_id)
DO UPDATE SET
    quantity   = EXCLUDED.quantity,     -- EXCLUDED = 今回挿入しようとした値
    updated_at = EXCLUDED.updated_at;

SELECT product_id, quantity FROM inventory WHERE product_id = 1;
-- → quantity = 100（上書きされた）

-- ---- 7-4. 複数行の UPSERT（バッチ処理）------------------
-- VALUES に複数行書ける。バッチインポートでよく使う。

INSERT INTO inventory (product_id, quantity)
VALUES
    (1,  200),
    (2,  150),
    (3,  300)
ON CONFLICT (product_id)
DO UPDATE SET
    quantity   = EXCLUDED.quantity,
    updated_at = NOW();

SELECT product_id, quantity FROM inventory WHERE product_id IN (1, 2, 3);

-- ---- 7-5. ON CONFLICT に WHERE を付ける（条件付きUPDATE）-
-- 新しい値の方が大きいときだけ更新する（在庫の最大値管理などに使える）

INSERT INTO inventory (product_id, quantity)
VALUES (1, 50)    -- 現在の quantity=200 より小さい
ON CONFLICT (product_id)
DO UPDATE SET
    quantity = EXCLUDED.quantity
WHERE EXCLUDED.quantity > inventory.quantity;   -- 新しい値の方が大きいときだけ更新

SELECT product_id, quantity FROM inventory WHERE product_id = 1;
-- → 200 のまま変わっていない（50 < 200 なので WHERE 条件を満たさなかった）


