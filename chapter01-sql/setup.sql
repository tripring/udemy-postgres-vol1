-- ============================================================
-- Chapter 01: 実務SQL（ウィンドウ関数・JSONB）事前セットアップ
-- ============================================================
-- 実行コマンド:
--   psql -h localhost -U udemart -d udemart -f setup.sql
-- ============================================================

-- ============================================================
-- 既存データをリセット
-- ============================================================
TRUNCATE order_items, orders, inventory, products, categories, customers RESTART IDENTITY CASCADE;

-- ============================================================
-- カテゴリ（10件）
-- ============================================================
INSERT INTO categories (name) VALUES
  ('電子機器'),
  ('家具・インテリア'),
  ('衣類・ファッション'),
  ('食品・飲料'),
  ('書籍・雑誌'),
  ('スポーツ・アウトドア'),
  ('おもちゃ・ホビー'),
  ('美容・コスメ'),
  ('自動車用品'),
  ('その他');

-- ============================================================
-- 商品（100件）
-- JSONB の attributes はカテゴリごとに異なる属性を持つ
-- ============================================================

-- JSONB カラムを追加（存在しなければ）
ALTER TABLE products ADD COLUMN IF NOT EXISTS attributes JSONB;

INSERT INTO products (name, category_id, price, description)
SELECT
    CASE ((g - 1) % 10) + 1
        WHEN 1 THEN '電子機器_' || g
        WHEN 2 THEN 'インテリア_' || g
        WHEN 3 THEN 'ファッション_' || g
        WHEN 4 THEN '食品_' || g
        WHEN 5 THEN '書籍_' || g
        WHEN 6 THEN 'スポーツ_' || g
        WHEN 7 THEN 'ホビー_' || g
        WHEN 8 THEN 'コスメ_' || g
        WHEN 9 THEN '自動車用品_' || g
        ELSE 'その他_' || g
    END,
    ((g - 1) % 10) + 1,
    ((random() * 49990) + 10)::NUMERIC(10, 2),
    'UdeMart商品_' || g || 'の説明文。'
FROM generate_series(1, 100) g;

-- カテゴリごとに JSONB 属性を設定
UPDATE products SET attributes =
    CASE category_id
        WHEN 1 THEN -- 電子機器
            jsonb_build_object(
                'color',          (ARRAY['ブラック','ホワイト','シルバー'])[((id - 1) % 3) + 1],
                'warranty_years', ((id % 3) + 1)
            )
        WHEN 2 THEN -- 家具・インテリア
            jsonb_build_object(
                'material', (ARRAY['木製','スチール','プラスチック'])[((id - 1) % 3) + 1],
                'width_cm',  ((id % 5) * 20) + 40,
                'height_cm', ((id % 4) * 15) + 60
            )
        WHEN 3 THEN -- 衣類・ファッション
            jsonb_build_object(
                'color',    (ARRAY['レッド','ブルー','グリーン','ホワイト','ブラック'])[((id - 1) % 5) + 1],
                'size',     (ARRAY['S','M','L','XL'])[((id - 1) % 4) + 1],
                'material', (ARRAY['綿','ポリエステル','ウール'])[((id - 1) % 3) + 1]
            )
        WHEN 4 THEN -- 食品・飲料
            jsonb_build_object(
                'contents_g',  ((id % 5) * 100) + 100,
                'allergens',   CASE WHEN id % 3 = 0 THEN '["小麦","卵"]'::jsonb
                                    WHEN id % 3 = 1 THEN '["乳","大豆"]'::jsonb
                                    ELSE '[]'::jsonb END
            )
        WHEN 8 THEN -- 美容・コスメ
            jsonb_build_object(
                'skin_type', (ARRAY['乾燥肌','混合肌','脂性肌','敏感肌'])[((id - 1) % 4) + 1],
                'volume_ml', ((id % 4) * 50) + 50
            )
        ELSE
            jsonb_build_object('tag', 'general')
    END;

-- ============================================================
-- 顧客（1,000件）
-- ============================================================
INSERT INTO customers (name, email, prefecture)
SELECT
    '顧客_' || g,
    'user_' || g || '@example.com',
    (ARRAY[
        '東京都', '大阪府', '神奈川県', '愛知県', '北海道',
        '福岡県', '埼玉県', '千葉県', '兵庫県', '静岡県'
    ])[(g % 10) + 1]
FROM generate_series(1, 1000) g;

-- ============================================================
-- 注文（2024年1〜12月、合計約24,000件）
-- 月別に件数に差をつけて季節変動を再現する
-- ============================================================
DO $$
DECLARE
    v_month     INT;
    v_count     INT;
    v_base_date TIMESTAMPTZ;
BEGIN
    FOR v_month IN 1..12 LOOP
        -- 月によって注文数を変える（11〜12月は多め）
        v_count := CASE v_month
            WHEN 1  THEN 1400
            WHEN 2  THEN 1300
            WHEN 3  THEN 1600
            WHEN 4  THEN 1800
            WHEN 5  THEN 1900
            WHEN 6  THEN 2000
            WHEN 7  THEN 2000
            WHEN 8  THEN 2100
            WHEN 9  THEN 2000
            WHEN 10 THEN 2400
            WHEN 11 THEN 2800
            WHEN 12 THEN 3400
        END;

        v_base_date := make_timestamptz(2024, v_month, 1, 0, 0, 0);

        INSERT INTO orders (customer_id, status, total_amount, ordered_at)
        SELECT
            ((random() * 999) + 1)::INTEGER,
            (ARRAY['confirmed','shipped','delivered','cancelled'])
                [(random() * 3 + 1)::INTEGER],
            ((random() * 19990) + 10)::NUMERIC(12, 2),
            v_base_date
                + ((random() * 27)::INTEGER || ' days')::INTERVAL
                + ((random() * 86399)::INTEGER || ' seconds')::INTERVAL
        FROM generate_series(1, v_count) g;
    END LOOP;
END;
$$;

-- ============================================================
-- 注文明細（orders に 1:1 で紐付け）
-- ============================================================
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
    o.id,
    ((random() * 99) + 1)::INTEGER,
    1,
    o.total_amount
FROM orders o;

-- ============================================================
-- 在庫（100件）
-- ============================================================
INSERT INTO inventory (product_id, quantity)
SELECT id, (random() * 200 + 1)::INTEGER
FROM products;

-- ============================================================
-- 統計情報を更新
-- ============================================================
ANALYZE;

SELECT '=== Chapter 01 セットアップ完了 ===' AS status;

SELECT
    (SELECT COUNT(*) FROM customers)   AS 顧客数,
    (SELECT COUNT(*) FROM products)    AS 商品数,
    (SELECT COUNT(*) FROM orders)      AS 注文数,
    (SELECT COUNT(*) FROM order_items) AS 注文明細数;

SELECT
    TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
    COUNT(*)                                            AS 注文件数
FROM orders
GROUP BY DATE_TRUNC('month', ordered_at)
ORDER BY 月;
