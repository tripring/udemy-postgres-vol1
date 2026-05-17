# Chapter 02: パフォーマンスチューニング

## このチャプターで学ぶこと

- `pg_stat_activity` を使ってリアルタイムで実行中のクエリを監視する方法
- `pg_stat_statements` を使って過去のスロークエリを特定する方法
- `EXPLAIN` / `EXPLAIN ANALYZE` でクエリの実行計画を読み解く方法
- B-treeインデックスの仕組みと、`CREATE INDEX` による高速化
- 複合インデックスのカラム順序がなぜ重要なのか
- マテリアライズドビューを使って重い集計クエリをキャッシュする方法
- 生成AIを活用してクエリチューニングのアドバイスをもらうコツ
- **インデックスが効かない3つの罠**（型ミスマッチ・関数ラップ・列順スキップ）
- **使われていないインデックスを発見**して書き込み負荷を下げる方法
- **N+1問題・IN vs EXISTS・LIKE部分一致**など現場頻出のクエリパターン罠
- **統計情報のズレ**がプランナーの誤判断を引き起こすメカニズムと対策
- **OFFSETの性能トラップ**とキーセット方式によるスケーラブルなページネーション

---

## ストーリー：受注一覧画面が遅い

### 月曜日の朝、Slackに通知が届く

```
[カスタマーサポート → エンジニアチーム]
受注管理画面の一覧表示が最近すごく遅いです。
5秒以上待たされることがあって、オペレーターから苦情が来ています。
週末から始まったキャンペーンで注文数が増えたからでしょうか？
```

UdeMartの受注管理システムを担当している岡野くんはコーヒーを飲みながらメッセージを読んだ。
先週のキャンペーンで注文数が急増したのは知っていた。でも、画面が5秒以上かかるのは
さすがにおかしい。データ量が増えただけなら、もっと緩やかに遅くなるはずだ。

岡野くんはまず本番DBに接続し、何が起きているのかを調べることにした。

> **ポイント**: パフォーマンス問題を調査するときは、まず「今何が起きているか」を観察することから始める。
> 推測で動いてはいけない。計測して、証拠を集めてから対処する。

---

## 事前準備

学習用のデータセットを作成するため、まず `setup.sql` を実行します。
**注意**: 30万件の注文データを生成するため、完了まで1〜3分程度かかります。

```bash
psql -f ~/udemy-postgres-vol1/chapter02-tuning/setup.sql
```

実行が完了すると、次のようなサマリーが表示されます。

```
summary
----------------------------------------------
完了: カテゴリ10件、商品1000件、顧客100000件、注文300000件、注文明細600000件
```

接続確認：

```bash
psql
```

psqlに入ったら、実行時間を表示する `\timing` を有効にしておきましょう。

```sql
\timing
```

---

## 実行中のクエリを調べる

### pg_stat_activity とは

PostgreSQLには、**現在DBで何が起きているかをリアルタイムで見せてくれるビュー**が用意されています。
それが `pg_stat_activity` です。Linuxの `top` コマンドのデータベース版だと思ってください。

このビューを見れば、今どのクエリが実行中で、どれくらい時間がかかっているかが一目でわかります。

### stateカラムの意味

| state | 意味 |
|---|---|
| `active` | 現在クエリを実行中 |
| `idle` | 接続は張られているが、何もしていない |
| `idle in transaction` | トランザクションを開いたまま放置している（要注意） |
| `idle in transaction (aborted)` | エラーが起きたトランザクションを放置している |

`idle in transaction` が長時間続いているセッションは、ロックを保持したままになっている可能性があり、
他のクエリをブロックする原因になります。見つけたら要調査です。

### 実行中の遅いクエリを見つけるSQL

```sql
-- 1秒以上かかっているクエリのみ表示
SELECT
    pid,
    now() - query_start AS duration,
    state,
    query
FROM pg_stat_activity
WHERE (now() - query_start) > INTERVAL '1 second'
  AND state = 'active'
ORDER BY duration DESC;
```

`now() - query_start` で「クエリが始まってからどれくらい経過したか」を計算しています。
これが大きいほど、長時間実行されているクエリです。

### psqlで\timingを有効にする

psql上でクエリの実行時間を表示するには `\timing` コマンドを使います。

```sql
\timing
-- 以降、すべてのクエリに実行時間が表示される
SELECT count(*) FROM orders;
-- Time: 42.183 ms
```

これはpsqlのセッション内だけで有効な設定です。接続し直すと無効になります。
常に有効にしたい場合は `~/.psqlrc` に `\timing` と書いておくと便利です。

---

## 過去のスロークエリを調べる

### pg_stat_statements とは

`pg_stat_activity` はリアルタイムの情報ですが、「この1週間で一番重かったクエリはどれか」を調べるには
別の手段が必要です。それが **`pg_stat_statements`** 拡張機能です。

`pg_stat_statements` を有効にすると、PostgreSQLはすべてのクエリの実行統計を記録し続けます。
「このクエリは何回実行されたか」「平均何ミリ秒かかったか」「合計何行返したか」が蓄積されていくのです。

`setup.sql` で `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;` を実行しているので、
すでに有効になっています。

### mean_exec_timeでソートしてTOP10を見る

```sql
SELECT
    calls,
    round(mean_exec_time::NUMERIC, 2) AS mean_ms,
    round(total_exec_time::NUMERIC, 2) AS total_ms,
    rows,
    left(query, 100) AS query_snippet
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

### 各カラムの読み方

| カラム | 読み方 |
|---|---|
| `calls` | このクエリが何回実行されたか |
| `mean_exec_time` | 1回あたりの平均実行時間（ミリ秒） |
| `total_exec_time` | 合計実行時間（ミリ秒）。`calls × mean_exec_time` のおよその値 |
| `rows` | このクエリが返した（または影響を与えた）行の合計数 |

**調査の視点が2つあります：**

1. **mean_exec_timeでソート** → 1回が重いクエリを見つける。バッチ処理や複雑な集計クエリが候補。
2. **total_exec_timeでソート** → 全体のDBへの負荷が大きいクエリを見つける。軽いクエリでも頻繁に呼ばれると合計負荷は大きくなる。

岡野くんの場合、受注一覧画面のクエリは「1回が重い」タイプのはず。
`mean_exec_time` でソートしたリストの上位を見ていくと、`orders` や `customers` を
結合しているクエリが5,000ms以上かかっているのが見つかるでしょう。

### pg_stat_statements.resetで統計をリセットする

チューニング作業が終わったあとや、テスト前後の比較をしたいときは統計をリセットできます。

```sql
SELECT pg_stat_statements_reset();
```

これを実行すると全統計がゼロになります。本番環境でうっかり実行しないよう注意してください。

---

## クエリを解析する（EXPLAIN / EXPLAIN ANALYZE）

### EXPLAINとEXPLAIN ANALYZEの違い

スロークエリが特定できたら、次はそのクエリが「なぜ遅いか」を調べます。
そのためのツールが `EXPLAIN` です。

| コマンド | 動作 | 実際に実行するか |
|---|---|---|
| `EXPLAIN` | クエリプランナーが「こう実行する予定」という計画を表示 | しない |
| `EXPLAIN ANALYZE` | 実際にクエリを実行し、計画と実測値の両方を表示 | する |

`EXPLAIN` だけであれば実際にはデータを読まないので安全です。
`EXPLAIN ANALYZE` は実際に実行されるため、`SELECT` 以外（`UPDATE`, `DELETE`）に使う場合は
トランザクションで囲んでロールバックするのが安全です。

```sql
BEGIN;
EXPLAIN ANALYZE UPDATE orders SET status = 'cancelled' WHERE id = 1;
ROLLBACK;
```

### Seq ScanとIndex Scanの違い

EXPLAINの出力でまず確認すべきは、**どのようにデータをスキャンしているか**です。

**Seq Scan（シーケンシャルスキャン）**
テーブルの最初の行から最後の行まで、全件を読み込みます。
30万件のテーブルなら30万件全部を読む。データ量が増えるほど遅くなります。

```
Seq Scan on orders  (cost=0.00..8561.00 rows=300000 width=60)
```

**Index Scan（インデックススキャン）**
インデックスという「目次」を使って、必要な行だけを素早く見つけます。
30万件のテーブルでも、条件に合う100件だけをピンポイントで取得できます。

```
Index Scan using idx_orders_status_ordered_at on orders
  (cost=0.42..156.23 rows=98 width=60)
```

大量データに対して条件絞り込みをするなら、Seq ScanよりIndex Scanのほうが圧倒的に速い。
EXPLAINを見て「Seq Scan」が出ていたら、インデックス追加を検討するサインです。

### cost=X..Y の読み方

```
Seq Scan on orders  (cost=0.00..8561.00 rows=300000 width=60)
```

- `cost=0.00..8561.00`：最初の数値が**起動コスト**（最初の行を返すまでのコスト）、
  二番目が**総コスト**（全行を返し終えるまでのコスト）。単位はPostgreSQLが内部で使う相対的な値。
- `rows=300000`：クエリプランナーが予測する返却行数。
- `width=60`：1行あたりの平均バイト数。

コストの絶対値に意味はありませんが、**同じクエリのチューニング前後で比較する**ことに意味があります。
インデックス追加後にコストが劇的に下がっていれば、チューニングが効いている証拠です。

### actual time, rows, loops の読み方

`EXPLAIN ANALYZE` を実行すると、計画に加えて実測値が表示されます。

```
Index Scan using idx_orders_status_ordered_at on orders
  (cost=0.42..156.23 rows=98 width=60)
  (actual time=0.123..2.456 rows=94 loops=1)
```

- `actual time=0.123..2.456`：実際にかかった時間（ミリ秒）。最初の数値が最初の行を返すまでの時間、
  二番目が全行を返し終えた時間。
- `rows=94`：実際に返した行数。`rows=98`（予測）と近ければプランナーの精度が高い。
- `loops=1`：この処理が何回繰り返されたか。JOINのネストなどで複数回になることがある。

### 生成AIへの投げ方のコツ

`EXPLAIN ANALYZE` の出力は読み慣れると強力ですが、最初は難しく感じます。
そこで、**生成AIを活用する**のが効果的です。

次のような形でプロンプトを作ると質の高いアドバイスがもらえます。

```
以下のクエリが遅いです。EXPLAIN ANALYZEの結果とテーブル定義を見て、
最適化のアドバイスをください。

## クエリ
SELECT c.name, c.prefecture, COUNT(o.id) AS order_count,
       SUM(oi.quantity * oi.unit_price) AS total_spent
FROM customers c
JOIN orders o ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id = o.id
WHERE o.status = 'delivered' AND o.ordered_at >= '2024-01-01'
GROUP BY c.id, c.name, c.prefecture
ORDER BY total_spent DESC
LIMIT 20;

## EXPLAIN ANALYZEの出力
（ここにEXPLAIN ANALYZEの結果を貼り付ける）

## テーブル定義
（ここに関連テーブルの\d出力を貼り付ける）
```

**ポイント**：
- クエリだけでなく `EXPLAIN ANALYZE` の出力とテーブル定義を一緒に貼る
- 「遅い」だけでなく、どのくらい遅いか（実行時間）を伝える
- 「どのインデックスを追加すればよいか」「複合インデックスの順序は正しいか」など、具体的に聞く

---

## インデックスを追加する

### なぜインデックスで速くなるのか

受注一覧画面の調査で、岡野くんはようやく「どのSQLが遅いのか」を見つけた。
ここでいきなりSQLを書き換える前に、まず見るべきなのは検索条件だ。サポート担当が開いている画面は、ほとんどの場合「最近の注文」「特定ステータス」「特定顧客」のように、限られた条件で絞り込んでいる。

それなのにDBが毎回 `orders` テーブル全体を上から下まで読んでいたら、注文数が増えるほど画面は遅くなる。そこで登場するのがインデックスだ。

B-treeインデックスを本の「索引」に例えてみましょう。

1,000ページの本から「PostgreSQL」という単語が出てくるページを探すとき、
最初のページから順番に読んでいったら大変です（Seq Scanと同じ）。
でも索引があれば「PostgreSQL → 342, 567, 891ページ」と一瞬でわかります（Index Scanと同じ）。

PostgreSQLのB-treeインデックスは、データを**ソートされたツリー構造**で保持します。
`WHERE status = 'delivered'` のような条件があれば、ツリーを二分探索して
対象レコードに一瞬でたどり着けます。

### CREATE INDEX の基本構文

```sql
-- 基本形
CREATE INDEX インデックス名 ON テーブル名 (カラム名);

-- 例: ordersのstatusカラムにインデックスを作成
CREATE INDEX idx_orders_status ON orders (status);
```

インデックス名は省略もできますが、`idx_テーブル名_カラム名` の形式で明示的につけるのが
運用上わかりやすいです。

### 複合インデックス（カラムの順序が重要）

複数カラムにまたがる条件（`WHERE status = 'delivered' AND ordered_at >= '2024-01-01'`）には、
**複合インデックス**が効果的です。

```sql
CREATE INDEX IF NOT EXISTS idx_orders_status_ordered_at
    ON orders (status, ordered_at DESC);
```

**カラムの順序のルール**: 等値条件（`=`）のカラムを先に、範囲条件（`>=`, `<=`, `BETWEEN`）のカラムを後に置く。

理由：B-treeは左から順番に値を絞り込みます。`status = 'delivered'` で先に絞り込んでから
`ordered_at >= '2024-01-01'` で範囲を絞る、という流れが効率的です。
逆順（`ordered_at, status`）にしてしまうと、`status = 'delivered'` の絞り込みに
インデックスが使われません。

### EXPLAIN ANALYZEで効果を確認する

インデックス追加前後で `EXPLAIN ANALYZE` を実行して比較しましょう。

**追加前（Seq Scan）**：
```
Seq Scan on orders  (cost=0.00..8561.00 rows=300000 width=60)
                    (actual time=0.012..312.456 rows=300000 loops=1)
```

**追加後（Index Scan）**：
```
Index Scan using idx_orders_status_ordered_at on orders
  (cost=0.42..156.23 rows=98 width=60)
  (actual time=0.123..2.456 rows=94 loops=1)
```

`actual time` が `312ms` から `2ms` に激減しています。これがインデックスの効果です。

### インデックスのデメリット（書き込み時のオーバーヘッド）

インデックスにはデメリットもあります。

1. **ストレージ使用量が増える**: インデックスはデータとは別に保存されるため、ディスクを消費します。
2. **INSERT/UPDATE/DELETEが遅くなる**: データを変更するたびに、インデックスも更新する必要があります。
   インデックスが多すぎると書き込みが重くなります。
3. **メンテナンスが必要**: 大量のデータ更新後はインデックスが断片化することがあります。

**インデックスを作りすぎないこと**。すべてのカラムにインデックスを貼れば速くなるわけではありません。
「実際に遅いクエリ」「頻繁に使われるWHERE条件」に絞って追加するのが正しいアプローチです。

---

## マテリアライズドビューで集計を高速化

### マテリアライズドビューとは

キャンペーン翌週の朝、今度は経営企画部の高橋くんから連絡が来た。

> 「受注一覧は速くなったんですが、経営ダッシュボードの売上グラフがまだ重いです。朝会のたびに開くので、毎回待たされるのがつらくて」

岡野くんが確認すると、ダッシュボードを開くたびに、同じ日次売上集計が実行されていた。

1. `orders` からキャンセル以外の注文を読む
2. 注文日ごとに `GROUP BY` する
3. 件数、売上合計、平均注文額を計算する
4. グラフ用に日付順で返す

この集計は便利だが、毎回リアルタイムに再計算する必要があるだろうか。高橋くんが見たいのは「昨日までの売上推移」であり、秒単位で変わる数字ではない。つまり、多少古くてもよい代わりに、何度開いても速く返ってほしいデータだ。

このように「毎日の売上集計」のような同じ重い集計クエリを何度も実行している場合は、**マテリアライズドビュー**が有効です。

通常の `VIEW` は、参照するたびに内部でSELECT文を実行します。
つまり、通常のVIEWは「クエリの別名」にすぎず、参照するたびに毎回計算が走ります。

一方、**マテリアライズドビュー（Materialized View）** は集計結果を実際のテーブルとして
ディスクに保存します。参照するときは保存済みの結果を読むだけなので、高速です。

ただし、保存した結果は自動では最新になりません。ここで大切なのは、「速さ」と「データの新鮮さ」のどちらを優先する画面なのかを判断することです。

| 比較項目 | 通常のVIEW | マテリアライズドビュー |
|---|---|---|
| 参照速度 | 毎回クエリを実行（遅い） | 保存済み結果を読む（速い） |
| データの新鮮さ | 常に最新 | リフレッシュするまで古い |
| ストレージ | 使わない | 使う |
| 向いているケース | 常に最新データが必要 | 多少古くてもよい集計レポート |

### CREATE MATERIALIZED VIEW

```sql
CREATE MATERIALIZED VIEW mv_daily_sales AS
SELECT
    DATE(ordered_at)          AS sale_date,
    COUNT(*)                  AS order_count,
    SUM(total_amount)         AS total_sales,
    AVG(total_amount)::NUMERIC(12, 2) AS avg_order_amount
FROM orders
WHERE status != 'cancelled'
GROUP BY DATE(ordered_at)
ORDER BY sale_date DESC;
```

これを実行すると、集計結果が `mv_daily_sales` というマテリアライズドビューに保存されます。
次回から `SELECT * FROM mv_daily_sales` で参照するときは、集計クエリは実行されず、
保存済みデータが返ってきます。

### REFRESH MATERIALIZED VIEW CONCURRENTLY

新しい注文が入るたびにマテリアライズドビューのデータは古くなっていきます。
最新化するには `REFRESH` コマンドを使います。

岡野くんは高橋くんに確認した。

> 「このダッシュボード、朝会では昨日までの数字が正しければ大丈夫ですか？それとも、今この瞬間の売上まで必要ですか？」

答えは「昨日までで十分」だった。そこで、毎朝4時にリフレッシュする運用にした。深夜バッチ後に集計を作り直し、日中のダッシュボードは保存済みの結果を読むだけにする。

```sql
-- 通常のリフレッシュ（参照がブロックされる）
REFRESH MATERIALIZED VIEW mv_daily_sales;

-- CONCURRENTLYをつけると参照をブロックしない（本番環境向け）
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;
```

`CONCURRENTLY` オプションをつけることで、リフレッシュ中でも他のセッションがビューを
参照し続けられます。ただし `CONCURRENTLY` を使うには、ビューに**ユニークインデックス**が
必要です。

```sql
-- CONCURRENTLY使用のために必須
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_daily_sales_sale_date
    ON mv_daily_sales (sale_date);
```

### ユースケース：日次売上レポート

UdeMartの日次売上レポートは、経営ダッシュボードで毎分参照されています。
そのたびに30万件の注文テーブルを集計していたら、DBに大きな負荷がかかります。しかも、同じ集計結果を複数の人が何度も見ているだけなら、DBはほとんど同じ仕事を繰り返していることになります。

実際の運用パターン：

1. 毎朝4時にバッチで `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;` を実行
2. ダッシュボードは `mv_daily_sales` を参照（高速）
3. 当日分は多少古くても問題ない（前日までの売上は正確）

逆に、在庫数、決済状態、配送ステータスのように「今この瞬間の値」が重要なデータには向きません。マテリアライズドビューは、古くてもよい集計を速く読むための選択肢です。

---

## WITH句（CTE）で複雑なJOINを分割する

### 実務でよくある「JOINが増えるほど遅くなる」問題

機能追加を繰り返すと、1つのSELECT文が10テーブル以上を結合するようになることがあります。
インデックスを追加しても劇的に改善しない場合、**クエリの構造そのもの**が問題のことが多いです。

UdeMartでも同様の問題が発生しうる状況が考えられます。たとえばマーケティング会議で、皆川くんが「顧客ランク別に、どのカテゴリの商品が伸びているか見たい」と依頼してきたとします。

必要なデータは `customers`、`orders`、`order_items`、`products`、`categories`。最初は素直に全部JOINすればよさそうに見えます。しかし条件が増えるたびにJOINの順序が複雑になり、読み手にもプランナーにも負担の大きいSQLになっていきます。

こういうとき、岡野くんは「一度に全部やる」のをやめて、処理を意味のある単位に分けます。先に対象期間の注文を絞る、次に明細を足す、最後にカテゴリ別に集計する。WITH句（CTE）は、その分割をSQLの中で表現するための道具です。

### なぜ多テーブルJOINは遅いのか

PostgreSQLのクエリプランナーは、テーブルを結合する順序を自動で最適化しようとします。
しかし **テーブル数が増えるほど、組み合わせ数が爆発的に増え**、プランナーが最適解を見つけにくくなります。

さらに問題なのが、**絞り込み前に巨大なテーブルを結合してしまう**パターンです。

```
❌ 悪い例（先に全件結合してから絞り込む）
customers (10万行) × orders (30万行) × order_items (60万行) → WHERE で絞り込む

✅ 良い例（先に絞り込んでから結合する）
orders から WHERE条件に合う数万行だけ取得 → order_items と結合 → customers と結合
```

### WITH句（CTE）で分割する

WITH句を使うと、クエリを「段階的に」書けます。
各CTEに名前をつけて、前の結果を次のCTEで使う構造です。

```sql
-- ① 条件に合う注文だけ先に取り出す（30万件 → 数万件に圧縮）
WITH target_orders AS (
    SELECT id, customer_id
    FROM orders
    WHERE status = 'delivered'
      AND ordered_at >= '2024-01-01'
),
-- ② 絞り込んだ注文の明細を集計（小さいセット同士の結合）
spending_summary AS (
    SELECT
        t.customer_id,
        oi.product_id,
        SUM(oi.quantity * oi.unit_price) AS amount
    FROM target_orders t
    JOIN order_items oi ON oi.order_id = t.id
    GROUP BY t.customer_id, oi.product_id
)
-- ③ 最後に静的マスタ（顧客・商品）を付加
SELECT
    c.name, c.prefecture, cat.name AS category, SUM(s.amount) AS total_spent
FROM spending_summary s
JOIN customers c    ON c.id   = s.customer_id
JOIN products p     ON p.id   = s.product_id
JOIN categories cat ON cat.id = p.category_id
GROUP BY c.id, c.name, c.prefecture, cat.name
ORDER BY total_spent DESC LIMIT 20;
```

### CTEの設計原則

| 優先度 | 考え方 |
|--------|-------|
| ① | 最初のCTEで最も大きなテーブルを条件で絞り込む |
| ② | 1つのCTEに結合するテーブルは3〜4個に留める |
| ③ | 静的マスタ（customers, products等）は最後に結合する |
| ④ | 各CTEの件数をデバッグして想定通りか確認する |

### MATERIALIZED キーワード（PostgreSQL 12以降の注意点）

PostgreSQL 12以降、CTEはデフォルトで**インライン展開**されます。
= プランナーがCTEの境界を越えて最適化できる（多くの場合はこれで良い）

ただし「必ずここで絞り込んでから次に進む」と明示したいときは `MATERIALIZED` をつけます。

```sql
WITH target_orders AS MATERIALIZED (  -- ← 必ずここで評価する
    SELECT id, customer_id FROM orders
    WHERE status = 'delivered' AND ordered_at >= '2024-01-01'
)
...
```

`MATERIALIZED` をつけると、プランナーがCTEを変形しないことが保証されます。
複雑なクエリで「プランナーが予期しない最適化をして逆に遅くなった」ときの対処にも使えます。

---

---

## インデックスが効かない3つの罠

インデックスを作成したのに `EXPLAIN` を見るとまだ `Seq Scan` が出ている。これは現場でよく起きる問題です。

岡野くんが `EXPLAIN ANALYZE` を見ると、インデックスを作ったはずの列で `Seq Scan` が出ていることがあります。PostgreSQLが意地悪をしているわけではありません。SQLの書き方によっては、せっかくのインデックスを使えない形にしてしまうことがあります。

原因は大抵3つのどれかです。

### 罠①：型ミスマッチ（暗黙キャストでインデックス無効）

**外部キーの型が親テーブルと違う**ケースです。これは特に古いシステムの移行時や、テーブルを別々の人が設計したときに起きがちです。

```sql
-- 親テーブル: id は INTEGER (SERIAL)
\d orders
-- id | integer | ...

-- 子テーブルの order_id が NUMERIC になっていたとする
-- CREATE TABLE order_logs (order_id NUMERIC, ...);
-- CREATE INDEX ON order_logs(order_id);

-- JOIN するとき PostgreSQL は INTEGER と NUMERIC を比較するために
-- 暗黙的にキャスト（型変換）を走らせる
-- → インデックスの型と一致しないためインデックスが使われない
EXPLAIN SELECT * FROM orders o JOIN order_logs ol ON o.id = ol.order_id;
-- → Seq Scan on order_logs（インデックス無視）

-- 正しくは型を合わせる
-- CREATE TABLE order_logs (order_id INTEGER, ...);
```

`EXPLAIN` に `Filter: ((order_id)::integer = o.id)` のようなキャストが見えたら型ミスマッチのサインです。

**確認方法：**

```sql
-- 外部キー列の型を一覧で確認する
SELECT
    tc.table_name,
    kcu.column_name,
    c.data_type,
    ccu.table_name  AS ref_table,
    ccu.column_name AS ref_column,
    c2.data_type    AS ref_data_type
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
JOIN information_schema.columns c
    ON c.table_name = tc.table_name AND c.column_name = kcu.column_name
JOIN information_schema.columns c2
    ON c2.table_name = ccu.table_name AND c2.column_name = ccu.column_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND c.data_type != c2.data_type;  -- 型が違うものだけ抽出
```

### 罠②：関数でくるんでインデックス無効

**WHERE 句でカラムを関数に通すとインデックスが使われません。** B-tree インデックスは「元の値」でソートされているため、変換後の値では検索できないのです。

```sql
-- NG: UPPER()でくるむとインデックスが効かない
WHERE UPPER(email) = 'TEST@EXAMPLE.COM'

-- NG: ::date でキャストするとインデックスが効かない
WHERE created_at::date = '2024-01-01'

-- NG: date_trunc でくるむとインデックスが効かない
WHERE date_trunc('day', ordered_at) = '2024-01-01'
```

**解決策①：式インデックスを作る（クエリを変えたくない場合）**

```sql
-- UPPER(email) の結果にインデックスを張る
CREATE INDEX IF NOT EXISTS idx_customers_email_upper ON customers (UPPER(email));

-- これで UPPER(email) = '...' がインデックスを使えるようになる
EXPLAIN SELECT * FROM customers WHERE UPPER(email) = 'TEST@EXAMPLE.COM';
-- → Index Scan on customers
```

**解決策②：WHERE 句の書き方を変える（推奨）**

```sql
-- NG: ::date キャストで1日分だけ検索
WHERE ordered_at::date = '2024-01-01'

-- OK: 範囲条件に書き直す（インデックスがそのまま効く）
WHERE ordered_at >= '2024-01-01' AND ordered_at < '2024-01-02'
```

### 罠③：複合インデックスの先頭列をスキップ

複合インデックスは **左から順に** 使われます。先頭列を省略した条件では効きません。

```sql
-- インデックス定義: (status, ordered_at)
CREATE INDEX IF NOT EXISTS idx_orders_status_ordered_at ON orders (status, ordered_at DESC);

-- OK: 先頭列(status)を等値条件で使っている
WHERE status = 'delivered' AND ordered_at >= '2024-01-01'
-- → Index Scan

-- NG: 先頭列(status)を使っていない
WHERE ordered_at >= '2024-01-01'
-- → Seq Scan（インデックスが効かない）
```

**覚え方：電話帳は「姓→名」の順に並んでいる。名前だけで探しても見つからない。**

複合インデックスを設計するときの原則：

| 優先順位 | カラムの種類 | 例 |
|---|---|---|
| ① 先頭 | 等値条件（`=`）のカラム | `status = 'delivered'` |
| ② 次 | 等値条件（`=`）のカラム（複数なら全部先に） | `user_id = 100` |
| ③ 末尾 | 範囲条件（`>=`, `<=`, `BETWEEN`）のカラム | `ordered_at >= '2024-01-01'` |

---

## 使われていないインデックスを発見する

パフォーマンス対応が続くと、「念のため作ったインデックス」が増えていきます。
最初は画面を速くするための対策だったものが、いつの間にかINSERTやUPDATEを重くする原因になることがあります。

インデックスは読み取りを速くする反面、**INSERT / UPDATE / DELETE のたびに更新コストが発生します**。使われていないインデックスは「遅くするだけの重荷」です。

岡野くんは、追加するだけでなく、使われなくなったインデックスを見つけて整理するところまでをチューニングと考えるようにした。

### pg_stat_user_indexes で使用状況を確認する

```sql
-- idx_scan が 0 のインデックス = 一度も使われていないインデックス
SELECT
    schemaname,
    relname                                            AS table_name,
    indexrelname                                       AS index_name,
    idx_scan                                           AS times_used,
    pg_size_pretty(pg_relation_size(indexrelid))       AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;
```

`idx_scan = 0` かつサイズが大きいものは削除候補です。

> **注意**: サーバー再起動や `pg_stat_reset()` で統計がリセットされます。十分な期間（最低1〜2週間）が経過してから判断しましょう。

### インデックスの使用頻度と書き込みコストを比較する

```sql
-- インデックスごとに「使われた回数」と「書き込み更新回数」を比較
SELECT
    i.relname                                          AS index_name,
    s.idx_scan                                         AS read_uses,
    s.idx_tup_read                                     AS tuples_read,
    pg_size_pretty(pg_relation_size(i.oid))            AS index_size,
    t.n_tup_ins + t.n_tup_upd + t.n_tup_del           AS write_ops
FROM pg_stat_user_indexes s
JOIN pg_class i ON i.oid = s.indexrelid
JOIN pg_stat_user_tables t ON t.relid = s.relid
WHERE s.schemaname = 'public'
ORDER BY s.idx_scan ASC, write_ops DESC;
```

`read_uses` が少なく `write_ops` が多いインデックスは、コストに見合っていない可能性があります。

### 不要なインデックスの削除

```sql
-- 本番では事前にバックアップし、まずCONCURRENTLYで削除を試みる
-- CONCURRENTLY を使うとテーブルロックなしで削除できる
DROP INDEX CONCURRENTLY IF EXISTS idx_orders_old_column;
```

---

## クエリパターンの罠

インデックスは正しく貼れていても、**クエリの書き方そのものが問題**になるケースがあります。
特に怖いのは、開発環境では速いのに、本番データ量や本番アクセス数になった瞬間に遅くなるパターンです。

ここでは、UdeMartのAPIや検索画面で起きがちなクエリの罠を見ていきます。

### 罠①：N+1問題

**N+1問題**は ORM（アプリ側のDB操作ライブラリ）を使う開発でよく起きる問題です。「1件のリクエストで1回クエリ → その結果のN件それぞれにもう1回クエリ」で合計N+1回DBにアクセスするパターンです。

```sql
-- アプリがこういうループを回していたとする
SELECT * FROM customers WHERE id = 1;  -- 1回目
SELECT * FROM orders WHERE customer_id = 1;  -- 2回目（顧客1のぶん）
SELECT * FROM orders WHERE customer_id = 2;  -- 3回目（顧客2のぶん）
-- ... 顧客が100人いれば合計101回のクエリが発行される
```

`pg_stat_statements` で発見できます。同じクエリが `calls` で数百〜数千回実行されていたら N+1 のサインです。

```sql
-- calls が異常に多いクエリを探す
SELECT
    calls,
    round(mean_exec_time::NUMERIC, 2) AS mean_ms,
    round(total_exec_time::NUMERIC, 2) AS total_ms,
    left(query, 120) AS query_snippet
FROM pg_stat_statements
WHERE calls > 1000
ORDER BY calls DESC
LIMIT 10;
```

**解決策：JOIN または ANY でまとめて取得する**

```sql
-- NG: N+1（ループ内で1件ずつ取得）
SELECT * FROM orders WHERE customer_id = $1;  -- これがN回発行される

-- OK: まとめて取得（1回のクエリで済む）
SELECT c.name, o.id, o.status, o.total_amount
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE c.id = ANY(ARRAY[1, 2, 3, ...]);
```

### 罠②：IN句のサブクエリはスケールしない

`WHERE id IN (サブクエリ)` は、サブクエリの結果が数件のときは速いですが、**数万件になると急激に遅くなる**ことがあります。

```sql
-- データが少ないうちは速い→増えると急に遅くなるパターン
WHERE customer_id IN (
    SELECT id FROM customers WHERE prefecture = '東京都'
);

-- EXISTS に書き換えると大抵速くなる
WHERE EXISTS (
    SELECT 1 FROM customers
    WHERE customers.id = orders.customer_id
      AND customers.prefecture = '東京都'
);

-- または JOIN に書き換える
SELECT o.*
FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE c.prefecture = '東京都';
```

`EXPLAIN` を見て、`IN` のサブクエリが `Seq Scan` になっていたら要書き換えです。

### 罠③：LIKE 部分一致はインデックスが効かない

```sql
-- 前方一致（%は末尾だけ）→ B-tree インデックスが効く
WHERE name LIKE '山田%'   -- OK

-- 部分一致・後方一致（先頭に%）→ B-tree インデックスが効かない
WHERE name LIKE '%山田%'  -- Seq Scan になる
WHERE name LIKE '%山田'   -- Seq Scan になる
```

**解決策：pg_trgm 拡張 + GIN インデックス**

`pg_trgm` は文字列を3文字のグラム（trigram）に分解してインデックスを作る拡張です。`LIKE '%キーワード%'` でもインデックスが使えるようになります。

```sql
-- 拡張を有効化
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- GIN インデックスを作成
CREATE INDEX ON customers USING GIN (name gin_trgm_ops);

-- これで LIKE '%山田%' にもインデックスが効くようになる
EXPLAIN SELECT * FROM customers WHERE name LIKE '%山田%';
-- → Bitmap Index Scan on customers（GINインデックス使用）
```

---

## 統計情報のズレとプランナーの誤判断

ある日、同じSQLなのに日によって速かったり遅かったりする、という相談が来た。
インデックスはある。SQLも大きく変わっていない。それでも実行計画だけが変わってしまう。

PostgreSQL のクエリプランナーは「どのインデックスを使うか」「どの順でテーブルを結合するか」を**統計情報**を元に判断します。統計が古いと、プランナーが最悪の実行計画を選んでしまいます。

### 統計情報とは何か

PostgreSQL は `ANALYZE` コマンドを実行するたびに、テーブルごとに以下を記録します：

- 行数の推定値
- カラムの値の分布（どの値が何件あるか）
- NULL の割合

これが `EXPLAIN` の `rows=XXX`（予測行数）に使われています。

### 予測行数と実行行数のズレを確認する

`EXPLAIN ANALYZE` で `rows`（予測）と `actual rows`（実測）を比べます。

```
Seq Scan on orders
  (cost=0.00..8561.00 rows=300000 width=60)   ← プランナーの予測
  (actual time=..        rows=12 loops=1)      ← 実際の行数
```

**予測300,000行 → 実際12行**という乖離があれば、統計情報が古すぎてプランナーが正しく判断できていません。

### 統計が古くなるケース

1. **大量データを一気にINSERTした後**：AUTOVACUUM が動くまでの間、統計が古いまま
2. **特定の値が急増した**（例：`status = 'pending'` の件数が急増）：分布の変化に統計が追いついていない
3. **テーブルを削除して作り直した**：統計が初期化される

### 手動で ANALYZE を実行する

```sql
-- テーブル単体
ANALYZE orders;

-- テーブル + カラムを指定（特定カラムの統計だけ更新）
ANALYZE orders (status, ordered_at);

-- データベース全体（バッチ後などに実行）
ANALYZE;
```

大量データ投入後は必ず `ANALYZE` を実行する習慣をつけましょう。

### EXPLAIN の rows 乖離を確認する方法

```sql
-- EXPLAIN ANALYZE を実行して rows と actual rows の差を目視で確認する
EXPLAIN ANALYZE
SELECT * FROM orders WHERE status = 'delivered';

-- rows= の数値（予測）と actual rows= の数値（実測）を比べる
-- 10倍以上の乖離があれば ANALYZE を実行する
```

### 拡張統計（複数カラムの相関）

単一カラムの統計だけでは不十分な場合があります。たとえば `prefecture` と `city` は相関があり（「東京都渋谷区」は多いが「北海道渋谷区」はない）、これを PostgreSQL は単独では知りません。

```sql
-- 複数カラムの組み合わせ統計を作成（PostgreSQL 10以降）
CREATE STATISTICS stat_prefecture_city
    ON prefecture, city FROM customers;

ANALYZE customers;

-- これ以降、(prefecture, city) の組み合わせの推定精度が上がる
```

---

## OFFSETの罠とキーセット方式

最後に、画面設計とSQLがぶつかる典型例を扱います。
受注一覧画面には「次へ」「前へ」があります。最初の数ページは速いのに、500ページ目、1000ページ目を開くと急に遅くなる。サポート担当から見ると同じ一覧画面ですが、DBから見るとまったく違う重さの処理になっていることがあります。

### OFFSET はなぜ遅いのか

`LIMIT ... OFFSET n` は直感的で使いやすいが、PostgreSQL の内部では「先頭から n 行を読み捨てる」という処理が走っている。ページが後半になるほど読み捨てる行数が増え、スキャンコストが線形に増大する。

```sql
-- 1ページ目（速い）
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC
LIMIT 20 OFFSET 0;

-- 5,000ページ目（遅い！100,000行読み捨ててから20行返す）
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC
LIMIT 20 OFFSET 100000;
```

インデックスが使われていても、OFFSET 分の行を読み飛ばす処理はなくならない。300,000件のテーブルで最終ページを表示しようとすると、実質フルスキャンに近いコストになる。

### EXPLAIN ANALYZE でコストを確認する

```sql
EXPLAIN ANALYZE
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC
LIMIT 20 OFFSET 0;
-- → cost が小さく、actual rows=20 で高速

EXPLAIN ANALYZE
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC
LIMIT 20 OFFSET 100000;
-- → Offset コストが大きい。rows fetched は 100,020 になっている
```

### キーセット方式（カーソルページネーション）

解決策は「最後に取得した行の値を次の WHERE 条件にする」方法だ。インデックスが使えれば、どのページでも同じコストで動く。

```sql
-- 初回（1ページ目）
SELECT id, ordered_at, total_amount
FROM orders
ORDER BY ordered_at DESC, id DESC   -- ソートキーは一意に特定できる組み合わせにする
LIMIT 20;
-- → 最後の行の (ordered_at, id) をクライアントが保持する

-- 次ページ（前ページの末尾を WHERE 条件に使う）
SELECT id, ordered_at, total_amount
FROM orders
WHERE (ordered_at, id) < ('2024-11-15 10:23:45', 98765)   -- 前ページ末尾の値
ORDER BY ordered_at DESC, id DESC
LIMIT 20;
```

この方式では「ページ番号」という概念がなくなり、代わりに「どこまで取得したか」を示す **カーソル**（前ページ末尾の値）をクライアントが保持する。

### 比較と使い分け

| 方式 | 仕組み | 適した場面 | 注意点 |
|---|---|---|---|
| OFFSET | 先頭から n 行スキップ | ページ数が少ない（〜数百ページ）/ 任意ページへ直接ジャンプ | 大量データで後半ページが遅くなる |
| キーセット | 前ページの末尾を WHERE 条件に | API・無限スクロール / 大量データの逐次取得 | 任意ページへの直接ジャンプが難しい |

ECサイトの商品検索結果（数百万件）や API のリスト系エンドポイントではキーセット方式が向いている。管理画面でページ数が少ない（〜30ページ程度）場合は OFFSET で十分だ。

---

## まとめ

このチャプターでは、パフォーマンス問題の調査から解決まで一通りの流れを学びました。

岡野くんが今回やったことは、単にインデックスを貼ることではありません。まず「今遅いクエリ」を見つけ、実行計画で理由を確認し、必要な場所だけ改善しました。そのあと、集計のキャッシュ、JOINの分割、インデックスが効かない書き方、不要インデックスの整理、統計情報、ページネーションまで、現場で続けて出てくる問題を順番に潰していきました。

**学んだこと**:

1. `pg_stat_activity` でリアルタイムに実行中のクエリを監視できる
2. `pg_stat_statements` で過去の実行統計から重いクエリを特定できる
3. `EXPLAIN ANALYZE` でクエリの実行計画と実測値を確認できる
4. Seq Scanが出ていたらインデックス追加を検討するサイン
5. 複合インデックスは「等値条件のカラム → 範囲条件のカラム」の順で作る
6. インデックスは書き込み負荷を増やすため、本当に必要なものだけ追加する
7. マテリアライズドビューで重い集計クエリをキャッシュして高速化できる
8. WITH句（CTE）で「先に絞り込んでから結合する」構造にすることで多テーブルJOINを高速化できる
9. 型ミスマッチ・関数ラップ・先頭列スキップの3パターンがインデックスを無効化する
10. `pg_stat_user_indexes` で使われていないインデックスを発見して削除できる
11. N+1問題は `pg_stat_statements` の `calls` 異常値で発見できる
12. `IN（サブクエリ）` は大量データでスケールしない → `EXISTS` または `JOIN` に書き換える
13. `LIKE '%キーワード%'` は `pg_trgm` + GINインデックスで解決できる
14. 統計情報のズレが実行計画の誤判断を引き起こす → `ANALYZE` で解消する
15. OFFSET はページが深くなるほど遅くなる → 大量データには WHERE + ソートキーのキーセット方式を使う

**パフォーマンスチューニングの鉄則**:

> 計測せずに推測で動いてはいけない。
> `EXPLAIN ANALYZE` で証拠を確認してから、インデックスを追加する。
> インデックスは「貼れば速くなる」ではない。型・関数・列順の罠を知った上で設計する。

**次のチャプターの予告**:

Chapter 03では **ロックとデッドロック** を扱います。
「なぜかUPDATEが詰まって画面がフリーズする」という別の問題が発生したUdeMart。
ロックの仕組み、デッドロックの原因と対処法、長時間トランザクションの危険性を学びます。
