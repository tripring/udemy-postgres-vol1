# Chapter 04: パーティショニング

## このチャプターで学ぶこと

- テーブルの肥大化がなぜクエリを遅くするのかを理解する
- PostgreSQL のパーティショニング（`PARTITION BY RANGE`）でテーブルを月単位に分割する
- パーティションプルーニングにより、直近1ヶ月のデータだけを高速に読み出せることを確認する
- パーティションの追加・デタッチという日常運用の手順を習得する

---

## ストーリー：問題発生

UdeMart のバックエンドエンジニア・岡野くんは月曜の朝、経営企画部の高橋くんからメッセージを受け取った。

> 「岡野くん、先週の月次売上レポート、まだ出ていないんですが……SQL が全然終わらなくて。昨日も10分待ったのですが途中で諦めました」

岡野くんがクエリを確認すると、月ごとの売上を集計するごく普通の GROUP BY だ。去年の同じクエリは数秒で終わっていたはずなのに、なぜ今は10分以上かかるのか。

```sql
-- 高橋くんが使っていた月次レポートのクエリ
SELECT
    DATE_TRUNC('month', ordered_at) AS month,
    count(*) AS order_count,
    sum(total_amount) AS revenue
FROM orders
GROUP BY 1
ORDER BY 1;
```

岡野くんが `pg_stat_user_tables` を確認すると、`orders` テーブルのタプル数が **500万件** を超えていた。UdeMart はサービス開始から3年。初年度は月に数万件だった注文が、今や月に数十万件に増えている。古いデータも新しいデータもすべて同じテーブルに積み上がり、高橋くんが「先月分だけ」を集計しようとしても、DBは5,000,000件全件をスキャンしてしまっていた。

**「パーティショニングを入れるべき時が来た」**—岡野くんはそう判断した。

---

## 事前準備

本チャプター用のサンプルデータを投入します。`setup.sql` を実行してください（500,000件の注文データを生成するため、数分かかります）。

```bash
psql -f ~/course/chapter04-partitioning/setup.sql
```

実行後、以下のような出力が表示されれば準備完了です。

```
注文件数: 500000、期間: 2022-01-01 〜 2024-12-31
```

---

## セクション1: パーティショニングとは

### 概念

**パーティショニング**とは、1つの論理テーブルを内部的に複数の物理テーブル（パーティション）に分割する仕組みです。アプリケーションからは1つのテーブルとして見えますが、実際のデータは条件（パーティションキー）に基づいて別々のストレージ領域に格納されます。

```
orders（論理テーブル）
├── orders_2022_01（物理テーブル：2022年1月分）
├── orders_2022_02（物理テーブル：2022年2月分）
├── ...
└── orders_2024_12（物理テーブル：2024年12月分）
```

### パーティションプルーニング

パーティショニング最大の恩恵が**パーティションプルーニング**（Partition Pruning）です。WHERE 句にパーティションキーの条件が含まれている場合、PostgreSQL は該当するパーティションだけを読みに行き、残りは完全に読み飛ばします。

```sql
-- ordered_at の条件があると、2024年1月のパーティションだけ読む
SELECT * FROM orders WHERE ordered_at >= '2024-01-01' AND ordered_at < '2024-02-01';
-- → orders_2024_01 だけスキャン（他の35パーティションは無視）
```

500万件のテーブルでも、1パーティションが約14万件なら、スキャン対象は 1/35 以下になります。

### いつパーティショニングを使うべきか

パーティショニングは万能ではなく、導入コストもあります。次のような条件が重なったときに検討しましょう。

| 条件 | 目安 |
|------|------|
| テーブルサイズ | 数百万行以上（少なくとも数十万行） |
| クエリパターン | 特定の期間・地域・カテゴリで絞り込む検索が多い |
| データライフサイクル | 古いデータを定期的にアーカイブ・削除したい |
| パーティションキー | WHERE 句に頻繁に登場するカラムがある |

行数が少ない段階でパーティショニングを入れると、管理コストだけが増えてほぼメリットがありません。EXPLAIN ANALYZE で `Seq Scan` が問題になってきたタイミングが判断のサインです。

### PostgreSQL のパーティション種類

| 種類 | キー | 典型的な用途 |
|------|------|------------|
| `RANGE` | 日付・数値の範囲 | 注文日、ログ日時、売上月 |
| `LIST` | 特定の値リスト | 都道府県、ステータス、地域コード |
| `HASH` | ハッシュ値 | 特定の範囲がなく均等分散したいケース |

本チャプターでは `orders.ordered_at`（注文日時）を使った **RANGE パーティショニング**を実装します。

---

## セクション2: 現状の問題を確認する

### テーブルサイズの確認

まず現在のテーブルサイズを確認します。

```sql
SELECT
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
    pg_size_pretty(pg_relation_size(oid)) AS table_size,
    pg_size_pretty(pg_total_relation_size(oid) - pg_relation_size(oid)) AS index_size
FROM pg_class
WHERE relname = 'orders';
```

`pg_total_relation_size` はインデックスを含む合計サイズ、`pg_relation_size` はテーブル本体のサイズです。数十 MB から数百 MB になっているはずです。

### EXPLAIN ANALYZE で全件スキャンを確認

月次レポートのクエリに `EXPLAIN ANALYZE` を付けて実行計画を確認します。

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    DATE_TRUNC('month', ordered_at) AS month,
    count(*) AS order_count,
    sum(total_amount) AS revenue
FROM orders
GROUP BY 1
ORDER BY 1;
```

出力の中に次のような行が現れます。

```
Seq Scan on orders  (cost=... rows=500000 ...) (actual time=... rows=500000 ...)
```

`Seq Scan`（シーケンシャルスキャン）は全件読み取りです。WHERE 句がないため、パーティショニングをしていない通常テーブルではこれは避けられません。`actual time` の値が大きいほど、パーティショニングの効果が際立ちます。

---

## セクション3: パーティションテーブルを作成する

### PARTITION BY RANGE の構文

```sql
CREATE TABLE テーブル名 (
    カラム定義 ...
) PARTITION BY RANGE (パーティションキーカラム);
```

これで「親テーブル」が作られます。親テーブル自体はデータを持たず、ルーティングのみを担います。

### 月単位のパーティション作成

子パーティションは `PARTITION OF` で親テーブルに紐づけます。`FOR VALUES FROM ... TO ...` の範囲は **左閉・右開**（FROM の値は含む、TO の値は含まない）です。

```sql
-- 2022年1月のパーティション（1月1日以上、2月1日未満）
CREATE TABLE orders_2022_01 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2022-01-01') TO ('2022-02-01');

-- 2022年2月
CREATE TABLE orders_2022_02 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2022-02-01') TO ('2022-03-01');
```

2022年1月〜2024年12月の36ヶ月分を作成するのは手作業では大変なので、`practice/02_create_partition.sql` では `generate_series` を使って一括生成する方法を示しています。

### PRIMARY KEY とパーティションキー

パーティションテーブルでは **プライマリキーにパーティションキーを含める**必要があります。

```sql
PRIMARY KEY (id, ordered_at)  -- ordered_at を含める
```

これは PostgreSQL のパーティショニングの制約で、「どのパーティションにあるかを特定するにはパーティションキーが必要」という設計によるものです。

### DEFAULT パーティション

定義した範囲に収まらない行は `DEFAULT` パーティションに入ります。

```sql
CREATE TABLE orders_default PARTITION OF orders_partitioned DEFAULT;
```

将来の日付や、想定外の過去データがここに入ります。`DEFAULT` パーティションを作っておかないと、定義外の値を INSERT したときにエラーになります。

### パーティションへのインデックス作成

親テーブルにインデックスを作ると、すべての子パーティションに自動的に同名のインデックスが作られます。

```sql
CREATE INDEX idx_orders_partitioned_ordered_at ON orders_partitioned (ordered_at);
CREATE INDEX idx_orders_partitioned_customer_id ON orders_partitioned (customer_id);
```

既存の子パーティションだけでなく、**将来追加する子パーティションにも自動で適用**されます。これはパーティショニングの大きな利点です。

---

## セクション4: データを移行する

既存の `orders` テーブルから新しい `orders_partitioned` テーブルへデータを移行します。

```sql
INSERT INTO orders_partitioned (id, customer_id, status, total_amount, ordered_at, shipped_at)
SELECT id, customer_id, status, total_amount, ordered_at, shipped_at
FROM orders;
```

500,000件の移行は数秒〜数十秒かかります。本番環境での大規模移行では、バッチ分割や論理レプリケーションを使ったオンライン移行を検討しますが、本チャプターではシンプルな `INSERT ... SELECT` で体験します。

移行後、件数が一致しているか確認します。

```sql
SELECT
    (SELECT count(*) FROM orders) AS original,
    (SELECT count(*) FROM orders_partitioned) AS partitioned;
```

---

## セクション5: パーティションプルーニングを確認する

### EXPLAIN ANALYZE で確認

移行が完了したら、同じクエリをパーティションテーブルで実行し、プルーニングが効いているか確認します。

```sql
EXPLAIN (ANALYZE, FORMAT TEXT)
SELECT DATE_TRUNC('day', ordered_at), count(*), sum(total_amount)
FROM orders_partitioned
WHERE ordered_at BETWEEN '2024-01-01' AND '2024-01-31'
GROUP BY 1
ORDER BY 1;
```

実行計画に次のような行が現れます。

```
Partitions selected: 1
```

36パーティションのうち1つだけが選択されていることが確認できます。スキャン対象が 1/36 になっているので、全件スキャンより大幅に高速です。

### 比較してみる

同じ WHERE 条件を元の `orders` テーブルでも実行してみると違いが明確です。

```sql
-- 元のテーブル → Seq Scan（全500,000件）
EXPLAIN ANALYZE
SELECT DATE_TRUNC('day', ordered_at), count(*), sum(total_amount)
FROM orders
WHERE ordered_at BETWEEN '2024-01-01' AND '2024-01-31'
GROUP BY 1;

-- パーティションテーブル → 1パーティションのみスキャン
EXPLAIN ANALYZE
SELECT DATE_TRUNC('day', ordered_at), count(*), sum(total_amount)
FROM orders_partitioned
WHERE ordered_at BETWEEN '2024-01-01' AND '2024-01-31'
GROUP BY 1;
```

`actual time` の差がパーティショニングの効果を物語っています。

---

## セクション6: 運用（パーティションの追加・削除）

### 新しい月のパーティションを追加する

2025年1月が始まる前に、パーティションを追加しておきます。

```sql
CREATE TABLE orders_2025_01 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
```

運用上は、毎月末に翌月のパーティションを作成する**定期ジョブ**を仕込んでおくのが一般的です。`pg_cron` 拡張や外部スケジューラーと組み合わせて自動化できます。

パーティションが存在しない日付に INSERT しようとすると、`DEFAULT` パーティションに入ります。`DEFAULT` パーティションが存在しない場合はエラーになるため、先回りして作成しておくことが重要です。

### 古いパーティションをデタッチしてアーカイブする

古いデータが不要になった場合、**パーティションをデタッチ**して論理テーブルから切り離すことができます。

```sql
-- 2022年1月のパーティションを親テーブルから切り離す
ALTER TABLE orders_partitioned DETACH PARTITION orders_2022_01;
```

`DETACH` したパーティションは**削除されず、独立したテーブルとして残ります**。`SELECT count(*) FROM orders_2022_01;` のように直接参照できます。

その後、本当に不要であれば `DROP TABLE orders_2022_01;` で削除、または別のデータベースやオブジェクトストレージへの退避（コールドアーカイブ）が可能です。

```
デタッチの流れ：
orders_partitioned（論理テーブル）
├── orders_2022_01 → DETACH → 独立テーブルとしてアーカイブ可能
├── orders_2022_02 → DETACH → DROP TABLE で削除可能
├── orders_2022_03（まだ接続中）
└── ...
```

### PostgreSQL 14 以降の CONCURRENTLY オプション

PostgreSQL 14 から `DETACH PARTITION ... CONCURRENTLY` が使えます。

```sql
ALTER TABLE orders_partitioned DETACH PARTITION orders_2022_01 CONCURRENTLY;
```

通常の `DETACH` はテーブルに排他ロックをかけるため、本番環境では業務停止を伴います。`CONCURRENTLY` を使うとロックを最小限に抑えてオンラインで切り離せます（ただし、完了までに時間がかかる場合があります）。

---

## まとめ

このチャプターでは、テーブルの肥大化という現実的な問題を題材に、パーティショニングの概念から実装・運用まで一通り体験しました。

| やったこと | 学んだこと |
|-----------|-----------|
| `EXPLAIN ANALYZE` で全件スキャンを確認 | Seq Scan が遅さの原因になる |
| `PARTITION BY RANGE` で親テーブル作成 | パーティションキーを PK に含める制約 |
| 月単位の子パーティション作成 | FROM/TO は左閉・右開 |
| `INSERT ... SELECT` でデータ移行 | パーティション先に自動ルーティングされる |
| `EXPLAIN ANALYZE` でプルーニング確認 | `Partitions selected: 1` で効果を確認 |
| パーティション追加・デタッチ | 運用の基本パターン |

### Vol.1 修了 / Vol.2 へ

Vol.1 はここで修了です。`chapter99-final/README.md` でコースを振り返りましょう。

続きは **Vol.2（運用・インフラ設計編）** で学べます。トリガー・バックアップ・レプリケーション・VACUUM・PgBouncer・監査ログとロール設計を扱います。

---

## ファイル構成

| ファイル | 内容 |
|---------|------|
| `README.md` | このファイル。チャプター全体の解説 |
| `setup.sql` | 事前データ投入スクリプト（500,000件生成） |
| `practice/` | セクションごとの SQL ファイル群 |
