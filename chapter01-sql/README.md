# Chapter 01: ウィンドウ関数・JSONB — 実務SQL

---

## このチャプターで学ぶこと

- **ウィンドウ関数**と `GROUP BY` の根本的な違いを理解する
- `OVER()` 句の構成要素（PARTITION BY / ORDER BY / フレーム句）を習得する
- `ROW_NUMBER` / `RANK` / `DENSE_RANK` でランキングを作る
- `SUM OVER` / `AVG OVER` で累計・移動平均を計算する
- `LAG` / `LEAD` で前後行の値を参照して前月比・変化量を求める
- `JSONB` を使って柔軟な属性データを格納・検索する
- GIN インデックスで JSONB 検索を高速化する
- `WITH RECURSIVE` で階層データ（カテゴリツリー等）を再帰的に取得する
- `INSERT ... ON CONFLICT` で「存在すれば更新、なければ挿入」を原子的に実行する

---

## ストーリー：「Excel職人からの脱却」

### 毎月末の憂鬱

UdeMartのマーケティング担当・皆川くんは毎月末が憂鬱だった。理由はひとつ——**月次売上レポートの作成**だ。

やっていることは毎回同じだ。

1. 「顧客ごとの累計購入金額」をSQLで取得 → Excelに貼り付け
2. 別のクエリで「前月の数字」を取得 → Excelで前月比を計算
3. 「カテゴリ別の売上ランキング」を別クエリで取得 → また別シートに貼り付け
4. 全部を手動で整形して経営会議に持ち込む

所要時間：毎月 **4〜5時間**。

ある日、エンジニアの岡野くんが手伝いを申し出た。

「皆川くん、それ全部1つのSQLで出せますよ。前月比もランキングも移動平均も込みで」

「……え？どういうこと？」

岡野くんが使ったのが **ウィンドウ関数** だ。

### 商品属性の管理問題

もうひとつ困っていることがある。商品の属性管理だ。

電子機器なら「保証年数・対応OS」、衣類なら「カラー・サイズ・素材」、食品なら「内容量・アレルゲン」。カテゴリが違えば必要な属性も違うのに、今のスキーマは全商品に同じカラムしか持てない。新しい属性が必要になるたびに `ALTER TABLE` でカラムを追加しているが、他のカテゴリにとってはほとんど `NULL` だらけの列が増えていくだけだ。

岡野くんの提案は「`JSONB` カラムを1つ追加して、カテゴリごとに自由なキーで属性を持てるようにする」だった。

---

## 事前準備

```bash
psql -f ~/course/chapter01-sql/setup.sql
```

このchapterの `setup.sql` は以下のデータを準備します。

| テーブル | 件数 | 備考 |
|---|---|---|
| customers | 1,000件 | 10都道府県 |
| products | 100件 | JSONB attributes カラム付き |
| orders | 約24,000件 | 2024年1〜12月、季節変動あり |
| order_items | 約24,000件 | 注文1件につき1明細 |
| inventory | 100件 | |

セットアップ完了時に月別注文件数が表示されます。11〜12月が多くなっていれば正常です。

その後、psqlに接続して `practice/` ディレクトリ内のファイルを順番に実行してください。

```bash
psql
```

---

## ウィンドウ関数とは何か

### GROUP BY との根本的な違い

ウィンドウ関数を理解する最重要ポイントは「**行を消すかどうか**」だ。

```sql
-- GROUP BY: 複数行を 1行に集約する（元の行は消える）
SELECT customer_id, SUM(total_amount) AS total
FROM orders
GROUP BY customer_id;
-- → customer_id ごとに 1行になる。個々の注文の情報は消える
```

```sql
-- ウィンドウ関数: 各行に集計結果を付与する（元の行は消えない）
SELECT
    customer_id,
    total_amount,
    ordered_at,
    SUM(total_amount) OVER (PARTITION BY customer_id) AS customer_total
FROM orders;
-- → 注文 1件ごとに 1行のまま。さらに「その顧客の合計金額」が各行に付く
```

**GROUP BY** は「集計した結果だけ欲しい」とき。  
**ウィンドウ関数** は「元の行を保持しながら、集計値も一緒に見たい」とき。

### OVER() 句の構成要素

```sql
関数名() OVER (
    PARTITION BY 列名   -- グループ分けの基準（省略可）
    ORDER BY 列名       -- 順序の基準（ランキング・累計に必要）
    ROWS BETWEEN ...    -- 計算対象の行範囲（省略可）
)
```

| 構成要素 | 役割 | 省略した場合 |
|---|---|---|
| `PARTITION BY` | この単位でリセット（GROUP BY 的な分割） | 全行を 1 グループとして扱う |
| `ORDER BY` | この順序で処理（ランキング・累計に必須） | 順序なし |
| フレーム句（`ROWS BETWEEN`） | 計算対象の行範囲を指定 | `ORDER BY` がある場合は先頭行から現在行まで |

---

## ランキング（ROW_NUMBER / RANK / DENSE_RANK）

### 3つのランキング関数の違い

同点（同じ売上金額）があったとき、3つの関数は異なる結果を返す。

| 関数 | 同点の扱い | 次の順位 | 使いどころ |
|---|---|---|---|
| `ROW_NUMBER()` | 1, 2, 3, 4（常に連番） | 続く | ページネーション・重複排除 |
| `RANK()` | 1, 1, 3, 4（同位で次は飛ぶ） | 飛ぶ | 競技・賞レース |
| `DENSE_RANK()` | 1, 1, 2, 3（同位で次は続く） | 続く | カテゴリ内ランキング |

### 顧客ごとの累計購入金額ランキング

```sql
SELECT
    c.name                                               AS 顧客名,
    SUM(o.total_amount)                                  AS 累計購入金額,
    RANK() OVER (ORDER BY SUM(o.total_amount) DESC)      AS ランキング,
    ROUND(
        SUM(o.total_amount)
            / SUM(SUM(o.total_amount)) OVER () * 100,
        2
    )                                                    AS 全体シェア率
FROM orders o
JOIN customers c ON c.id = o.customer_id
GROUP BY c.id, c.name
ORDER BY ランキング
LIMIT 20;
```

`SUM(SUM(o.total_amount)) OVER ()` の `OVER()` が空なのは「全顧客合計」を計算するため。`PARTITION BY` がなければ全行が 1 グループになる。

### カテゴリ内での商品売上ランキング（PARTITION BY の威力）

```sql
SELECT
    cat.name                                                      AS カテゴリ,
    p.name                                                        AS 商品名,
    SUM(oi.quantity * oi.unit_price)                              AS 売上合計,
    DENSE_RANK() OVER (
        PARTITION BY cat.id
        ORDER BY SUM(oi.quantity * oi.unit_price) DESC
    )                                                             AS カテゴリ内順位
FROM order_items oi
JOIN products   p   ON p.id   = oi.product_id
JOIN categories cat ON cat.id = p.category_id
GROUP BY cat.id, cat.name, p.id, p.name
ORDER BY cat.name, カテゴリ内順位;
```

`PARTITION BY cat.id` により、カテゴリごとにランキングが**リセット**される。「電子機器部門1位」と「衣類部門1位」が同じ結果セットに共存できる。これが `PARTITION BY` の核心だ。

### 実務応用：カテゴリ内上位3商品だけを抽出

```sql
SELECT カテゴリ, 商品名, 売上合計, カテゴリ内順位
FROM (
    SELECT
        cat.name                                                      AS カテゴリ,
        p.name                                                        AS 商品名,
        SUM(oi.quantity * oi.unit_price)                              AS 売上合計,
        DENSE_RANK() OVER (
            PARTITION BY cat.id
            ORDER BY SUM(oi.quantity * oi.unit_price) DESC
        )                                                             AS カテゴリ内順位
    FROM order_items oi
    JOIN products   p   ON p.id   = oi.product_id
    JOIN categories cat ON cat.id = p.category_id
    GROUP BY cat.id, cat.name, p.id, p.name
) ranked
WHERE カテゴリ内順位 <= 3
ORDER BY カテゴリ, カテゴリ内順位;
```

`GROUP BY` だけではこの絞り込みは書けない。集計後に「カテゴリ内の順位で絞る」という操作が必要で、それにはウィンドウ関数が不可欠だ。このパターンは実務でよく使われる「Top-N per group」クエリだ。

---

## 集計ウィンドウ（累計・移動平均）

### フレーム句とは

`ORDER BY` を指定したウィンドウ関数には、「どの範囲の行を計算対象にするか」を指定するフレーム句が使える。

```
ROWS BETWEEN 開始 AND 終了
```

| よく使うフレーム句 | 意味 |
|---|---|
| `UNBOUNDED PRECEDING AND CURRENT ROW` | 先頭行から現在行まで（累計に使う） |
| `2 PRECEDING AND CURRENT ROW` | 2行前から現在行まで（3行移動平均） |
| `1 PRECEDING AND 1 FOLLOWING` | 前後1行を含む3行（中心移動平均） |
| `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` | 全行（パーティション全体の合計など） |

### 月次売上の累計

```sql
SELECT
    TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
    SUM(total_amount)                                   AS 月次売上,
    SUM(SUM(total_amount)) OVER (
        ORDER BY DATE_TRUNC('month', ordered_at)
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                   AS 年初来累計
FROM orders
WHERE ordered_at >= '2024-01-01'
GROUP BY DATE_TRUNC('month', ordered_at)
ORDER BY 月;
```

`SUM(SUM(total_amount))` という二重の `SUM` に見えるが、これは：
- 内側の `SUM(total_amount)` : GROUP BY で月次合計を計算
- 外側の `SUM(...) OVER (...)` : その月次合計をウィンドウで累積

GROUP BY と ウィンドウ関数は同じ SELECT 内で共存でき、GROUP BY が先に適用されてからウィンドウ関数が適用される。

### 直近3ヶ月移動平均

```sql
SELECT
    TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
    SUM(total_amount)                                   AS 月次売上,
    ROUND(
        AVG(SUM(total_amount)) OVER (
            ORDER BY DATE_TRUNC('month', ordered_at)
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
        0
    )                                                   AS 直近3ヶ月移動平均
FROM orders
WHERE ordered_at >= '2024-01-01'
GROUP BY DATE_TRUNC('month', ordered_at)
ORDER BY 月;
```

`ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` は「2行前〜現在行（計3行）の平均」。移動平均は月次変動のノイズを除いてトレンドを把握するのに有効で、売上ダッシュボードの定番指標だ。1〜2月は平均する行が足りないため少ない行数での平均になる。

---

## 前後行の参照（LAG / LEAD）

### LAG で前月比を計算する

```sql
SELECT
    月,
    月次売上,
    前月売上,
    CASE
        WHEN 前月売上 IS NULL THEN NULL
        ELSE ROUND((月次売上 - 前月売上) / 前月売上 * 100, 1)
    END AS 前月比率_pct
FROM (
    SELECT
        TO_CHAR(DATE_TRUNC('month', ordered_at), 'YYYY-MM') AS 月,
        SUM(total_amount)                                   AS 月次売上,
        LAG(SUM(total_amount), 1) OVER (
            ORDER BY DATE_TRUNC('month', ordered_at)
        )                                                   AS 前月売上
    FROM orders
    WHERE ordered_at >= '2024-01-01'
    GROUP BY DATE_TRUNC('month', ordered_at)
) t
ORDER BY 月;
```

`LAG(値, N)` は「N行前の値」を返す。1月は前月がないため `NULL` になる。このような「比率計算でNULLが混在するケース」はサブクエリに分けて書くと `LAG()` を1回で済ませられる。

`LEAD(値, N)` はその逆で「N行後の値」を返す。「翌月の達成目標を各行に付与する」といったケースで使える。

### 顧客の購入間隔を分析する

```sql
SELECT
    c.name                                               AS 顧客名,
    o.ordered_at::date                                   AS 注文日,
    o.total_amount                                       AS 注文金額,
    LAG(o.ordered_at::date) OVER (
        PARTITION BY o.customer_id
        ORDER BY o.ordered_at
    )                                                    AS 前回注文日,
    (o.ordered_at::date - LAG(o.ordered_at::date) OVER (
        PARTITION BY o.customer_id
        ORDER BY o.ordered_at
    ))                                                   AS 購入間隔_日
FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.customer_id IN (
    SELECT customer_id FROM orders
    GROUP BY customer_id HAVING COUNT(*) >= 3
)
ORDER BY o.customer_id, o.ordered_at
LIMIT 30;
```

`PARTITION BY customer_id` により、顧客ごとに `LAG` がリセットされる。各顧客の初回注文では前回がないため `購入間隔_日` は `NULL` になる。「N日以上購入のない顧客に再訪促進メールを送る」施策のベースクエリとして使える。

---

## JSONB 入門

### いつ JSONB を使うか

| ケース | JSONB が向いている理由 |
|---|---|
| カテゴリによって属性が異なる商品 | カテゴリごとに必要なキーが違い、統一カラムにできない |
| スキーマが頻繁に変わるデータ | `ALTER TABLE` なしで新属性を追加できる |
| 外部APIのレスポンスをそのまま保存 | 構造が決まっていない / 変わりうるデータ |
| 設定・メタデータ・タグ | アプリレベルで任意キーが必要なもの |

逆に「毎回 SELECT で参照する」「JOIN の条件になる」「NOT NULL が必要」な場合は通常のカラムにすべきだ。JSONB はあくまで補助的な柔軟スキーマ用途に使う。

### 基本演算子

```sql
-- attributes に各カテゴリの属性が入っている
SELECT id, name, attributes FROM products WHERE id = 1;
-- → attributes: {"color": "ブラック", "warranty_years": 1}

-- -> : キーを JSON 型で取得
SELECT attributes -> 'color' FROM products WHERE id = 1;
-- → "ブラック"（JSON 文字列、ダブルクォートが付く）

-- ->> : キーをテキスト型（TEXT）で取得
SELECT attributes ->> 'color' FROM products WHERE id = 1;
-- → ブラック（TEXT 型、ダブルクォートなし）

-- @> : 包含演算子 → 「このJSONBを含む行を返す」
SELECT * FROM products WHERE attributes @> '{"color": "ブラック"}';
-- → colorが"ブラック"の商品を返す（GINインデックスが効く）

-- ? : キーの存在チェック
SELECT * FROM products WHERE attributes ? 'warranty_years';
-- → warranty_years キーを持つ商品を返す
```

`->` と `->>`の違いは「型」。WHERE 条件で文字列比較するには `->>`（TEXT 型）を使い、`@>` で検索するときは演算子をそのまま使う。

### GIN インデックスで高速検索

```sql
-- GIN インデックスなしで実行計画を確認
EXPLAIN SELECT * FROM products WHERE attributes @> '{"color": "ブラック"}';
-- → Seq Scan（全件スキャン）

-- GIN インデックスを作成
CREATE INDEX idx_products_attributes ON products USING GIN (attributes);

-- インデックスありで実行計画を確認
EXPLAIN SELECT * FROM products WHERE attributes @> '{"color": "ブラック"}';
-- → Bitmap Index Scan on idx_products_attributes（インデックス利用！）
```

GIN（Generalized Inverted Index）は JSONB の全キー・全値に対してインデックスを張る。B-tree インデックスより容量は大きいが、JSONB の `@>` 検索には GIN が必須だ。`->>`を使った `=` 検索には B-tree インデックス (`CREATE INDEX ON products ((attributes->>'color'))`) が使える。

### 実務的なクエリパターン

```sql
-- カラーごとの商品数を集計
SELECT
    attributes ->> 'color' AS カラー,
    COUNT(*)               AS 商品数
FROM products
WHERE attributes ? 'color'      -- 'color' キーを持つ行だけ対象
GROUP BY attributes ->> 'color'
ORDER BY 商品数 DESC;

-- 保証年数が2年以上の電子機器を検索
SELECT name, attributes ->> 'warranty_years' AS 保証年数
FROM products
WHERE category_id = 1
  AND (attributes ->> 'warranty_years')::INTEGER >= 2;
-- ->> で取得した値は TEXT なので数値比較には ::INTEGER キャストが必要

-- jsonb_pretty で整形して表示（デバッグ時に便利）
SELECT id, name, jsonb_pretty(attributes) AS 属性詳細
FROM products
WHERE attributes IS NOT NULL
LIMIT 5;

-- 複数属性を同時に条件指定
SELECT name, attributes
FROM products
WHERE attributes @> '{"color": "ブラック", "material": "綿"}';
```

---

## 再帰CTE（WITH RECURSIVE）

### 階層データとは

UdeMartのカテゴリテーブルには `parent_id` カラムがある。「電子機器 → スマートフォン → ケース・カバー」のような親子関係を持つ構造だ。通常の JOIN では「何階層あるかわからない」データを一度に取得できないが、再帰CTEならどんな深さでも対応できる。

### 構文

```sql
WITH RECURSIVE cte名 AS (
    -- アンカー部（再帰の出発点）
    SELECT ...
    FROM テーブル
    WHERE 起点の条件

    UNION ALL

    -- 再帰部（cte名を参照して次の階層を取得）
    SELECT ...
    FROM テーブル
    JOIN cte名 ON 親子関係の条件
)
SELECT * FROM cte名;
```

アンカー部が最初の1行（または複数行）を返し、再帰部がその結果に対してさらに子を探す。「これ以上子がない」行に達したとき再帰が停止する。

### カテゴリツリー全体を取得する

```sql
WITH RECURSIVE category_tree AS (
    -- アンカー: ルートカテゴリ（親を持たない行）
    SELECT
        id,
        name,
        parent_id,
        0        AS depth,
        name::text AS path
    FROM categories
    WHERE parent_id IS NULL

    UNION ALL

    -- 再帰: 前の結果の id を parent_id に持つ行を取得
    SELECT
        c.id,
        c.name,
        c.parent_id,
        ct.depth + 1,
        ct.path || ' > ' || c.name
    FROM categories c
    JOIN category_tree ct ON c.parent_id = ct.id
)
SELECT depth, path, name
FROM category_tree
ORDER BY path;
```

`depth` は階層の深さ（0がルート）、`path` は「電子機器 > スマートフォン」のようなパス文字列だ。

### 特定カテゴリとその配下を全て取得する

```sql
WITH RECURSIVE sub_categories AS (
    SELECT id, name
    FROM categories
    WHERE id = 1              -- 「電子機器」を起点に

    UNION ALL

    SELECT c.id, c.name
    FROM categories c
    JOIN sub_categories sc ON c.parent_id = sc.id
)
SELECT * FROM sub_categories;
```

応用として、このカテゴリ一覧に JOIN すれば「電子機器およびその全サブカテゴリに属する商品」を一度に取得できる。

```sql
WITH RECURSIVE sub_categories AS (
    SELECT id FROM categories WHERE id = 1
    UNION ALL
    SELECT c.id FROM categories c
    JOIN sub_categories sc ON c.parent_id = sc.id
)
SELECT p.name, p.price
FROM products p
WHERE p.category_id IN (SELECT id FROM sub_categories)
ORDER BY p.price DESC;
```

---

## UPSERT（INSERT ... ON CONFLICT）

### 「存在すれば更新、なければ挿入」の問題

在庫管理では「商品IDがあれば在庫数を更新、なければレコードを作る」という処理が頻繁に発生する。素朴に実装すると複数ステップになる。

```
1. SELECT → レコードが存在するか確認
2. 存在すれば UPDATE
3. 存在しなければ INSERT
```

この方法は2セッションが同時に同じキーを処理したとき、どちらも「存在しない」と判断して INSERT を試みてしまう（重複キーエラー）。`INSERT ... ON CONFLICT` はこれを1文で**原子的に**解決する。

### ON CONFLICT DO NOTHING（無視）

```sql
-- すでに存在するキーは無視して、なければ挿入する
INSERT INTO inventory (product_id, quantity)
VALUES (1, 50)
ON CONFLICT (product_id) DO NOTHING;
```

「重複は無視してとにかく試みる」インポートバッチや冪等処理に便利だ。

### ON CONFLICT DO UPDATE（UPSERT）

```sql
-- 存在すれば在庫数を加算、なければ新規挿入
INSERT INTO inventory (product_id, quantity)
VALUES (1, 50)
ON CONFLICT (product_id)
DO UPDATE SET
    quantity   = inventory.quantity + EXCLUDED.quantity,
    updated_at = NOW();
```

`EXCLUDED` は「挿入しようとした値の行」を指す疑似テーブルだ。`EXCLUDED.quantity` で「今回挿入しようとした 50」を参照できる。

### 最新値で上書きするパターン

```sql
-- 外部システムからのデータ同期（最新値で常に上書き）
INSERT INTO inventory (product_id, quantity, updated_at)
VALUES (1, 100, NOW())
ON CONFLICT (product_id)
DO UPDATE SET
    quantity   = EXCLUDED.quantity,
    updated_at = EXCLUDED.updated_at;
```

マスタデータの定期同期や外部APIからのデータ取り込みでよく使うパターンだ。

### 使い分けまとめ

| 構文 | 動作 | 使いどころ |
|---|---|---|
| `ON CONFLICT DO NOTHING` | 重複行は無視して次へ | バッチインポート・冪等処理 |
| `ON CONFLICT DO UPDATE SET col = EXCLUDED.col` | 最新値で上書き | マスタ同期・ログ集約 |
| `ON CONFLICT DO UPDATE SET col = table.col + EXCLUDED.col` | 既存値に加算 | 在庫加算・カウンタ更新 |

---

## まとめと次のステップ

皆川くんの月次レポート作成時間は 4〜5時間から **30分以内** に短縮された。ランキング・前月比・移動平均すべてを SQL で自動生成できるようになったからだ。商品属性の問題も JSONB で解決し、新カテゴリ追加時に `ALTER TABLE` なしで対応できるようになった。

**重要ポイントの整理**

| 技術 | いつ使うか | 要注意ポイント |
|---|---|---|
| ウィンドウ関数（全般） | 行を消さずに集計・順位・前後参照が必要なとき | GROUP BY と組み合わせるとき処理順序に注意 |
| `ROW_NUMBER` | ページネーション・重複排除・1行目抽出 | 同点でも必ず連番になる |
| `RANK` / `DENSE_RANK` | 競技・順位表・Top-N per group | 同点の次順位の扱い方で使い分ける |
| `SUM` / `AVG OVER` | 累計・比率・移動平均 | フレーム句の指定範囲が結果を決める |
| `LAG` / `LEAD` | 前月比・変化量・購入間隔 | 先頭・末尾行は NULL になる |
| `JSONB` | 属性がカテゴリ依存・スキーマ可変なデータ | JOIN条件・NOT NULL が必要な列には不向き |
| GIN インデックス | JSONB の `@>` 検索を高速化 | B-tree より容量大。`->>` 検索には B-tree で対応 |
| `WITH RECURSIVE` | カテゴリツリー・組織図・BOMなど階層データの全取得 | 無限ループ防止に深さ上限を付けると安全 |
| `INSERT ... ON CONFLICT` | 「存在すれば更新、なければ挿入」を原子的に実行 | `EXCLUDED` 疑似テーブルで挿入値を参照できる |

**さらに深めるキーワード**

| テーマ | キーワード |
|---|---|
| ウィンドウ関数の応用 | `NTILE`（パーセンタイル分割）・`PERCENT_RANK`（相対順位）・`CUME_DIST`（累積分布） |
| JSONB の高度な操作 | `jsonb_set`（値の更新）・`jsonb_array_elements`（配列の展開）・`jsonb_to_record`（レコード変換） |
| 分析クエリ全般 | マテリアライズドビュー（集計結果のキャッシュ）・`LATERAL JOIN`（行ごとにサブクエリを変える） |
