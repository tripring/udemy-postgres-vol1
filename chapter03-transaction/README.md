# Chapter 03: トランザクション・ロック制御

---

## このチャプターで学ぶこと

- **トランザクション**とは何か、ACID特性とはどういう意味か
- `BEGIN` / `COMMIT` / `ROLLBACK` の基本操作
- 同時アクセスによる**競合状態（レースコンディション）**がどう発生するか
- **悲観ロック**（SELECT FOR UPDATE）で競合を防ぐ方法
- **楽観ロック**（versionカラム）で高パフォーマンスを維持しながら競合を検知する方法
- **デッドロック**とは何か、なぜ起きるか、防ぐにはどうすればよいか
- `pg_locks` / `pg_stat_activity` を使ったロック待ちのリアルタイム調査方法
- `SKIP LOCKED` によるジョブキューパターンの実装
- `ALTER TABLE` が引き起こすテーブルレベルロックと安全なオンラインDDL
- `lock_timeout` / `statement_timeout` で長時間ロックを防ぐ運用設計

---

## ストーリー：問題発生

### セール当日の朝

UdeMartでは年に一度の「フラッシュセール」を開催していた。目玉商品は**限定版ワイヤレスイヤホン**。定価12,800円のこの商品、在庫はなんと残り**1個**だ。セールページには「在庫わずか！」と大きく表示されており、数千人のユーザーがカートに入れてスタンバイしている。

午前10時、セール開始のカウントダウンがゼロになった瞬間、アクセスが殺到した。

### 二重購入の発生

顧客Aさん（東京都）と顧客Bさん（大阪府）が、ほぼ同時に購入ボタンを押した。バックエンドの処理は大まかに以下の流れだ。

```
1. inventory テーブルから在庫数を取得する
2. 在庫数 >= 1 であることを確認する
3. inventory.quantity を 1 減らす
4. orders / order_items に注文レコードを作る
5. 「購入完了」画面を表示する
```

顧客Aさんのリクエストと顧客Bさんのリクエストがほぼ同時に処理されると、次のような順序で実行される。

| 時刻 | 顧客Aさんのセッション | 顧客Bさんのセッション |
|------|---------------------|---------------------|
| 10:00:00.001 | `SELECT quantity` → **1** と取得 | |
| 10:00:00.002 | | `SELECT quantity` → **1** と取得 |
| 10:00:00.010 | `UPDATE quantity = 1 - 1` → 0 に更新 | |
| 10:00:00.011 | 購入完了！ | |
| 10:00:00.012 | | `UPDATE quantity = 1 - 1` → **-1** に更新 |
| 10:00:00.013 | | 購入完了！ |

どちらも「在庫が1個ある」と読んだ後、それぞれが在庫を1減らした。結果、`inventory.quantity = -1`。2人に「購入完了」メールが届いたが、発送できる商品は1個しかない。カスタマーサポートに問い合わせが殺到し、大慌てで対応することになった。

### 原因は何か？

問題の根本は「**読み取りと更新の間に隙間がある**」ことだ。在庫を読んだ時点ではどちらも「1個ある」という事実は正しい。しかし、読んだ後・更新するまでの間に、他のセッションが同じ行を変更してしまう可能性がある。この状態を**競合状態（レースコンディション）**と呼ぶ。

このチャプターでは、この問題をデータベースレベルで解決する方法を学ぶ。

この章では、悪化を実際に体験する。

- ロックなしで同時購入を走らせ、在庫がマイナスになる
- `SELECT FOR UPDATE` を使い、片方のセッションが待たされることを確認する
- ロック順序を逆にして、デッドロックを発生させる
- 長時間トランザクションが他の処理を止めることを確認する
- `lock_timeout` を設定し、待ち続けるのではなく早く失敗させる

トランザクションは、構文を知っているだけでは足りません。どの処理を待たせ、どの処理は待たせずにリトライさせるのかを判断できることが重要です。

---

## 事前準備

まず`setup.sql`を実行してサンプルデータを投入する。

```bash
psql -f ~/udemy-postgres-vol1/chapter03-transaction/setup.sql
```

実行すると以下のような出力が表示される。

```
--- 商品一覧 ---
 id |          name          |  price
----+------------------------+----------
  1 | 限定版ワイヤレスイヤホン | 12800.00
  2 | スマートウォッチ Pro    |  9800.00
  3 | モバイルバッテリー 20000mAh | 4980.00

--- 在庫確認 ---
           商品名            | 在庫数
-----------------------------+--------
 限定版ワイヤレスイヤホン     |      1  ← 残り1個！
 スマートウォッチ Pro         |     50
 モバイルバッテリー 20000mAh  |    100
```

その後、psqlに接続して `practice/` ディレクトリ内のファイルを順番に実行しながら学んでいく。

```bash
psql
```

---

## そもそもトランザクションとは

### ACID特性

データベースにおけるトランザクションは**ACID**という4つの特性を持つ。これはデータの整合性を保証するための約束事だ。

| 特性 | 英語 | 意味 |
|------|------|------|
| 原子性 | **A**tomicity | トランザクション内の処理はすべて成功するか、すべて失敗するかのどちらかしかない。一部だけ成功することはない。 |
| 一貫性 | **C**onsistency | トランザクションの前後で、データは常に整合した状態を保つ。制約（UNIQUE, NOT NULL など）は常に満たされる。 |
| 分離性 | **I**solation | 複数のトランザクションが同時に実行されても、互いに干渉しない。各トランザクションは「自分だけが動いている」かのように実行できる。 |
| 永続性 | **D**urability | COMMITされたデータはシステム障害が発生しても失われない。ディスクに書き込まれ永続化される。 |

冒頭のUdeMartの問題は、この中の**分離性（Isolation）**が不足していたために起きた。2つのトランザクションが互いに干渉してしまった。

### BEGIN / COMMIT / ROLLBACK の基本

PostgreSQLでは、明示的にトランザクションを開始する場合は`BEGIN`を使う。

UdeMartの購入処理では、在庫を減らすだけでは終わらない。注文を作り、注文明細を作り、決済状態を記録し、在庫を更新する。どれか1つだけ成功して他が失敗すると、ユーザーには購入完了と表示されたのに注文が存在しない、または在庫だけ減って注文がない、という壊れた状態になる。

そこで、岡野くんは「購入処理は1つのまとまりとして成功するか、まるごと失敗するか」にする必要があると考えた。これがトランザクションの基本的な役割だ。

```sql
BEGIN;

-- ここに複数のSQL文を書く
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;
INSERT INTO orders ...;
INSERT INTO order_items ...;

COMMIT;   -- すべてまとめて確定
-- または
-- ROLLBACK; -- すべてまとめて取り消し
```

トランザクション内の処理がエラーになった場合、PostgreSQLはそのトランザクションを「アボート状態」にする。アボート状態では以降のSQLコマンドはすべて無視され、`ROLLBACK`するまで抜け出せない。これが「原子性」の保証だ。

### autocommitとの違い

`BEGIN`を書かずにSQLを実行した場合、PostgreSQLは**autocommit**モードで動作する。つまり1文ごとに自動的にCOMMITされる。

```sql
-- autocommit: この1行だけで即座にCOMMITされる
UPDATE inventory SET quantity = 0 WHERE product_id = 1;
-- → すぐにディスクに書き込まれ、取り消せない
```

複数のテーブルをまとめて更新する処理（在庫を減らしながら注文を作るなど）は、必ず`BEGIN`〜`COMMIT`でひとまとめにしなければならない。途中でエラーが起きたとき、部分的に更新されたままにならないようにするためだ。

---

## 問題を再現してみる

### 2つのターミナルを用意する

問題を実際に体験するには、psqlを2つ起動して同時に操作する必要がある。ターミナルをA/Bの2つ開き、それぞれで接続する。

```bash
# ターミナルA
ssh student@localhost -p 2222
psql

# ターミナルB
ssh student@localhost -p 2222
psql
```

### 競合状態を再現するステップ

まずターミナルAで在庫を確認する。

```sql
-- ターミナルA
BEGIN;
SELECT quantity FROM inventory WHERE product_id = 1;
-- → 1
```

ターミナルBでも同じことをする。ロックが掛かっていないため、同じ値が見える。

```sql
-- ターミナルB
BEGIN;
SELECT quantity FROM inventory WHERE product_id = 1;
-- → 1（ターミナルAと同じ値！）
```

ここが問題の核心だ。どちらも「在庫が1個ある」と判断した。次にターミナルAが購入処理を完了させる。

```sql
-- ターミナルA
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;
COMMIT;
-- → quantity は 0 になった
```

続いてターミナルBが購入処理を実行する。

```sql
-- ターミナルB
UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 1;
COMMIT;
-- → quantity は -1 になってしまった！
```

この現象を確認することで、ロックがないとどれほど危険かが実感できる。

---

## 悲観ロック（SELECT FOR UPDATE）

### 考え方

在庫が残り1個の商品では、「あとで衝突したら考える」では間に合わない。購入ボタンを押した2人のうち、先に処理を始めた人が在庫行を確保し、もう一方はその処理が終わるまで待つ必要がある。

このように、競合しそうなデータを先にロックしてから更新する考え方が悲観ロックです。

「競合が起きる可能性があると悲観的に考え、読み取った時点でロックを取ってしまう」方法が**悲観ロック**だ。PostgreSQLでは`SELECT FOR UPDATE`という構文を使う。

```sql
BEGIN;
SELECT quantity
  FROM inventory
 WHERE product_id = 1
   FOR UPDATE;  -- ← この行を取得すると同時に排他ロックを取得する
```

`FOR UPDATE`を付けると、その行に**行レベルの排他ロック（Row Exclusive Lock）**が掛かる。他のセッションが同じ行に`FOR UPDATE`をしようとしたり、`UPDATE` / `DELETE`しようとすると、ロックを持つセッションが`COMMIT`または`ROLLBACK`するまで**待ち状態**になる。

なぜ「悲観的」と呼ぶかというと、「もしかしたら競合するかもしれない」という可能性を先に織り込んで、防衛的にロックを取るからだ。

### 2セッションで試すと

```sql
-- ターミナルA
BEGIN;
SELECT quantity FROM inventory WHERE product_id = 1 FOR UPDATE;
-- → 取得成功。ロックを保持している
```

この状態でターミナルBが同じ行を`FOR UPDATE`しようとすると…

```sql
-- ターミナルB
BEGIN;
SELECT quantity FROM inventory WHERE product_id = 1 FOR UPDATE;
-- → カーソルが点滅したまま、待ち続ける（ブロックされる）
```

ターミナルAが`COMMIT`した瞬間にターミナルBが動き出す。このとき取得できる`quantity`の値はターミナルAの更新後の値（0）になっているため、アプリ側で「在庫が0なので購入できません」と正しく返すことができる。

### NOWAIT オプション

ロック待ちが発生した場合に、待ち続けるのではなくすぐにエラーを返すオプションが`NOWAIT`だ。

```sql
SELECT quantity
  FROM inventory
 WHERE product_id = 1
   FOR UPDATE NOWAIT;
-- ロックが取れない場合:
-- ERROR: could not obtain lock on row in relation "inventory"
```

ユーザーに「現在混み合っています。少し待ってから再試行してください」というメッセージを即座に返したいケースに向いている。

### 安全な在庫更新パターン

```sql
BEGIN;

-- 在庫をロックしながら取得
SELECT quantity FROM inventory WHERE product_id = 1 FOR UPDATE;

-- 在庫があれば減らす
UPDATE inventory
   SET quantity = quantity - 1, updated_at = NOW()
 WHERE product_id = 1
   AND quantity >= 1;
-- UPDATE の影響行数が 0 なら「在庫切れ」としてROLLBACKする

INSERT INTO orders  ...;
INSERT INTO order_items ...;

COMMIT;
```

`SELECT FOR UPDATE`で読んだ行は、同じトランザクション内で`UPDATE`するまでロックが続く。他のセッションは読み取り後・更新前の隙間に割り込めないため、二重購入は起きない。

---

## 楽観ロック（versionカラムによる競合検知）

### 悲観ロックの問題点

一方で、すべての画面で悲観ロックを使うと、待ち時間が増えすぎます。
たとえば商品説明の編集やユーザー設定の更新は、同時に同じ行を触る頻度が低い処理です。毎回ロックで待たせるより、「もし他の人が先に更新していたら検知する」ほうが向いています。

悲観ロックは確実に競合を防いでくれるが、デメリットもある。

- **待ち時間が発生する**: ロックを取った処理が遅いと、他の全ユーザーが待たされる
- **スループットの低下**: 同時処理できる件数が制限される
- **デッドロックリスク**: 複数の行を複数のセッションがロックし合うと詰まりやすい

アクセス数が多いECサイトでは、この待ち時間が積み重なり、レスポンスタイムの悪化につながることがある。

### 楽観ロックの考え方

「競合はめったに起きない（楽観的）と仮定し、取得時はロックをかけない。その代わり、更新する直前に『自分が読んだあとに誰かが変更していないか』を確認する」。これが**楽観ロック**の考え方だ。

実装には`version`カラムを使うのが一般的だ。

```sql
ALTER TABLE inventory ADD COLUMN version INTEGER NOT NULL DEFAULT 1;
```

### 仕組み

1. 在庫を取得するとき、`version`も一緒に読み取る（例: `version = 1`）
2. 在庫を更新するとき、`WHERE version = 1`という条件を付ける
3. 自分が読んだ後に誰かが更新していれば`version`が変わっているため、この条件にマッチしない
4. `UPDATE`の影響行数が`0`なら「競合負け」とわかる → アプリ側で再試行を促す

```sql
-- 取得（ロックなし）
SELECT quantity, version FROM inventory WHERE product_id = 1;
-- → quantity=1, version=1

-- 更新（versionが変わっていないことを確認しながら）
UPDATE inventory
   SET quantity  = quantity - 1,
       version   = version + 1,   -- 成功したらバージョンを上げる
       updated_at = NOW()
 WHERE product_id = 1
   AND version   = 1;              -- ← ここがポイント
-- → 影響行数が 1 なら成功、0 なら競合（誰かに先を越された）
```

### 悲観ロックとの使い分け

| | 悲観ロック | 楽観ロック |
|---|---|---|
| 競合頻度 | 高い（在庫消化が激しい） | 低い（ほとんどのケース） |
| ロック待ち | 発生する | 発生しない |
| 競合時の動作 | 待ってから続行 | エラーを返し、アプリが再試行 |
| 実装の複雑さ | シンプル | やや複雑（影響行数チェックが必要） |

フラッシュセールのような「同時に何千人も同じ商品を購入しようとする」場面では悲観ロックが適している。通常の購入フローでは楽観ロックでも十分な場合が多い。

---

## デッドロック

### デッドロックとは

複数のトランザクションが互いに相手のロックを待ち合う状態を**デッドロック**という。例えばこういう状況だ。

| 時刻 | セッションA | セッションB |
|------|------------|------------|
| t1 | `UPDATE inventory WHERE product_id=1` → ロック取得 | |
| t2 | | `UPDATE inventory WHERE product_id=2` → ロック取得 |
| t3 | `UPDATE inventory WHERE product_id=2` → **待ち**（Bがロック中）| |
| t4 | | `UPDATE inventory WHERE product_id=1` → **待ち**（Aがロック中）|
| t5 | 永遠に待つ… | 永遠に待つ… |

AはBが`product_id=2`を解放するのを待っているが、BはAが`product_id=1`を解放するのを待っている。お互いに相手が動かないと動けない状態だ。

### PostgreSQLの自動検知

PostgreSQLはデッドロックを定期的に検知し（デフォルトは1秒ごと）、デッドロックと判断したらどちらか一方のトランザクションを強制的に`ROLLBACK`する。

```
ERROR: deadlock detected
DETAIL: Process 1234 waits for ShareLock on transaction 5678;
        blocked by process 9012.
        Process 9012 waits for ShareLock on transaction 5678;
        blocked by process 1234.
HINT: See server log for query details.
```

強制ROLLBACKされたセッションはエラーを受け取り、残りのセッションは正常に続行できる。

### pg_locksでロック状態を確認する

本番環境でロック待ちが疑われる場合、`pg_locks`ビューを使ってロックの状態を確認できる。

```sql
-- 現在のロック一覧
SELECT
    l.pid,
    l.relation::regclass AS table_name,
    l.mode,
    l.granted,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.relation IS NOT NULL;
```

`granted = false`の行が「ロック待ちをしているセッション」だ。また、どのプロセスがどのプロセスをブロックしているかを調べるには以下が便利だ。

```sql
SELECT
    blocked.pid         AS blocked_pid,
    blocked.query       AS blocked_query,
    blocking.pid        AS blocking_pid,
    blocking.query      AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;
```

### デッドロックを防ぐコツ

デッドロックは「たまたま起きる怖い現象」ではなく、設計でかなり減らせる現象です。
この教材では、わざとロック順序を逆にしてデッドロックを起こします。痛みを一度見ておくと、なぜロック順序の統一が重要なのかが一気に腹落ちします。

最も効果的な対策は「**複数の行をロックするときは、常に同じ順序でロックを取る**」ことだ。

```sql
-- NG: AはID昇順、BはID降順でロックするとデッドロックが起きやすい

-- OK: 常にID昇順でロックを取る
SELECT * FROM inventory
 WHERE product_id IN (1, 2, 3)
 ORDER BY product_id   -- ← 順序を統一！
   FOR UPDATE;
```

すべてのセッションが同じ順序でロックを取りに行けば、「すれ違い」が起きない。また、トランザクションの処理時間をできるだけ短くすること（ロックを長く持ち続けない）も重要だ。

---

## ロック調査と実運用テクニック

### なぜロック調査が重要か

本番環境では「クエリが突然遅くなった」「特定の操作が固まった」という報告が来ることがある。多くのケースでロック待ちが原因だ。問題発生時に素早く原因を特定できるかどうかが、障害の長期化を防ぐ鍵になる。

`practice/06_lock_investigation.sql` では、次の悪化を実際に作ります。

- `BEGIN` したまま放置し、`idle in transaction` が他セッションを待たせる様子を見る
- 通常の `CREATE INDEX` が書き込みを待たせる場面を作る
- `lock_timeout` なしでは待ち続け、`lock_timeout = '5s'` なら早く失敗することを比較する

ロック問題では、「待てばいつか終わる」ことが必ずしも正解ではありません。ユーザー画面、バッチ、管理操作のどれを待たせてよいのかを判断するために、待ち方と失敗のさせ方を体験します。

### pg_locks でロック待ちをリアルタイムに調べる

`pg_blocking_pids(pid)` は、指定したプロセスをブロックしているPIDの配列を返す組み込み関数だ。これを使うと「誰が誰を待っているか」を一発で可視化できる。

```sql
-- 待機中セッションとブロッキングセッションをまとめて確認
SELECT
    blocked.pid                       AS 待機PID,
    blocked.query                     AS 待機クエリ,
    now() - blocked.query_start       AS 待機時間,
    blocking.pid                      AS ブロッキングPID,
    blocking.query                    AS ブロッキングクエリ,
    blocking.state                    AS ブロッキング状態
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;
```

`state = 'idle in transaction'` のブロッキングセッションは特に危険だ。`BEGIN`を発行したまま何も実行せずに放置されており、ロックを持ち続けているがクエリを実行していない。アプリのバグやデプロイ時の接続放置でよく発生する。

### ブロッキングセッションを強制終了する

原因を特定したら `pg_cancel_backend` または `pg_terminate_backend` で対処できる。

```sql
-- クエリを中断するが接続は維持する（セッション側はエラーを受け取る）
SELECT pg_cancel_backend(ブロッキングPID);

-- セッションごと切断する（進行中のトランザクションはROLLBACKされる）
SELECT pg_terminate_backend(ブロッキングPID);
```

`pg_cancel_backend` はクエリを止めるだけなので、アプリが再接続してすぐ同じ処理を再実行する可能性がある。根本原因を調査してから判断すること。

### SKIP LOCKED でジョブキューを実装する

ECサイトの出荷処理やメール送信など、複数のワーカーが同じキューテーブルからジョブを取り出す場面では `FOR UPDATE SKIP LOCKED` が有効だ。

```sql
-- ワーカーが「未処理ジョブを1件取得して処理中にする」パターン
BEGIN;

SELECT id, payload
  FROM job_queue
 WHERE status = 'pending'
 ORDER BY created_at
 LIMIT 1
   FOR UPDATE SKIP LOCKED;
-- ロック中のジョブはスキップして、次の未処理ジョブを即座に取得する
-- 複数ワーカーがブロックし合わずに並列処理できる

UPDATE job_queue SET status = 'processing' WHERE id = <取得したID>;

COMMIT;
```

`SKIP LOCKED` がなければ、2つ目のワーカーは1つ目のワーカーが`COMMIT`するまで最初のジョブを待ち続けてしまう。

### ALTER TABLE が引き起こすテーブルレベルロック

DDL操作（ALTER TABLE）は `AccessExclusiveLock` という最強レベルのロックを取得する。このロックは `SELECT` さえもブロックするため、大きなテーブルへのALTERは本番環境で深刻な影響を与えうる。

```sql
-- 以下はすべて AccessExclusiveLock を取得する
ALTER TABLE orders ADD COLUMN notes TEXT;           -- NULLableなら比較的速い
ALTER TABLE orders ALTER COLUMN notes SET NOT NULL; -- 全行スキャンが発生
ALTER TABLE orders ADD CONSTRAINT ... FOREIGN KEY ...; -- 全行チェックが必要
```

| 操作 | ロックレベル | 注意点 |
|---|---|---|
| `ALTER TABLE ADD COLUMN (nullable)` | AccessExclusiveLock | 短時間。PostgreSQL 11+なら即完了 |
| `ALTER TABLE ADD COLUMN NOT NULL DEFAULT` | AccessExclusiveLock | 古バージョンでは全行書き換え |
| `CREATE INDEX` | ShareLock | INSERT/UPDATE/DELETE をブロック |
| `CREATE INDEX CONCURRENTLY` | 弱いロック | ほぼ影響なし（時間はかかる） |

大テーブルへのインデックス追加は `CREATE INDEX CONCURRENTLY` を使うことが鉄則だ。なお `CONCURRENTLY` はトランザクションブロック内では実行できない。

この章の実習では、通常の `CREATE INDEX` をトランザクション内で止め、別セッションのINSERTが待たされる状態を作ります。`CREATE INDEX` は検索を速くするための作業ですが、作り方を間違えると本番の書き込みを止める側になります。

### lock_timeout / statement_timeout で暴走を防ぐ

ロック待ちやクエリの長時間実行を自動で止めるには、タイムアウト設定を活用する。

```sql
-- セッションレベルで設定（この接続のみ有効）
SET lock_timeout = '5s';        -- 5秒以上ロック待ちが続いたらERROR
SET statement_timeout = '30s';  -- 30秒以上かかるクエリは強制終了

-- ロールレベルで設定（接続するたびに自動適用）
ALTER ROLE udemart SET lock_timeout = '10s';
ALTER ROLE udemart SET statement_timeout = '60s';
```

`lock_timeout` に引っかかるとエラーが返る。アプリ側では `LockNotAvailable` または `ERROR: canceling statement due to lock timeout` を受け取り、適切にリトライまたはユーザーへのエラー通知を行う。

本番環境では少なくとも `statement_timeout` は設定しておくことを強く推奨する。設定しないと、開発者が誤って書いたフルスキャンクエリや無限ループがDBリソースを食い尽くすリスクがある。

---

## まとめと次のチャプターへ

このチャプターで学んだことを振り返る。

| 技術 | いつ使うか | 注意点 |
|------|-----------|--------|
| `BEGIN`/`COMMIT`/`ROLLBACK` | 複数テーブルを一括更新するとき必ず | エラー時は必ずROLLBACKすること |
| `SELECT FOR UPDATE` | 競合頻度が高い処理（在庫減算、残高更新） | ロック待ちが発生することを考慮する |
| `SELECT FOR UPDATE NOWAIT` | 待ちたくない場合（すぐにエラーを返したい） | 競合時はアプリ側でリトライ処理が必要 |
| 楽観ロック（version） | 競合頻度が低い処理 | UPDATE影響行数のチェックが必須 |
| ロック順序の統一 | 複数行を更新する処理すべて | ORDER BYを使ってIDの昇順でロック |
| `pg_blocking_pids` | 本番でロック待ちが疑われるとき | `idle in transaction` を見逃さない |
| `SKIP LOCKED` | 複数ワーカーのジョブキュー処理 | LIMIT 1と組み合わせるのが定番 |
| `CREATE INDEX CONCURRENTLY` | 本番テーブルへのインデックス追加 | トランザクション内では使えない |
| `lock_timeout` / `statement_timeout` | 本番環境全般 | ロールレベルで設定しておくと安心 |

UdeMartの問題は`SELECT FOR UPDATE`を導入することで解決した。顧客Aさんと顧客Bさんが同時に購入ボタンを押しても、片方のセッションはもう一方が`COMMIT`するまでブロックされる。ブロックが解除されたとき在庫は既に0なので「申し訳ありません、在庫切れです」と正しく案内できるようになった。

**次のチャプター（Chapter 04）**では、データ量が急増したUdeMartのテーブルを**パーティショニング**で分割し、検索・削除のパフォーマンスを改善する方法を学ぶ。数百万行を超えたordersテーブルで月次の古いデータを瞬時に削除できるようになる。
