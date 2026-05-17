# Udemy PostgreSQL 実践講座 Vol.1 — 教材リポジトリ

本リポジトリは Udemy 講座「PostgreSQL 実践講座 Vol.1」の演習用 SQL ファイルと Docker 環境一式です。

## 教材構成

| ディレクトリ | 内容 |
|---|---|
| `chapter01-sql/` | ウィンドウ関数・JSONB・再帰CTE・全文検索など |
| `chapter02-tuning/` | EXPLAIN ANALYZE・インデックス・マテリアライズドビュー・統計情報など |
| `chapter03-transaction/` | トランザクション・排他制御・デッドロックなど |
| `chapter04-partitioning/` | テーブルパーティショニング |

各チャプターに `setup.sql`（初期データ投入）と `practice/`（演習ファイル）があります。

---

## クイックスタート

ホストPCに **Docker** が入っていれば OK です。Git のインストールは不要です。

### 1. 起動ファイルを取得

任意のディレクトリで以下を実行してください。

```bash
mkdir udemy-postgres && cd udemy-postgres
curl -O https://raw.githubusercontent.com/tripring/udemy-postgres-vol1/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/tripring/udemy-postgres-vol1/main/Dockerfile.bastion
```

### 2. Docker で環境を起動

```bash
docker compose up -d
```

初回は bastion イメージのビルドが走るため数分かかります。

### 3. 踏み台サーバーに SSH 接続

```bash
ssh -p 2222 student@localhost
# パスワード: student123
```

### 4. 教材をクローン

bastion 内で実行します（ここで初めて Git を使います）。

```bash
git clone https://github.com/tripring/udemy-postgres-vol1.git ~/course
```

### 5. 初期スキーマを作成

```bash
psql -f ~/course/chapter00-setup/init.sql
```

`psql` をそのまま実行するだけで PostgreSQL に繋がります。

```bash
psql
# udemart=#  と表示されれば OK
```

---

## 演習ファイルの実行方法

```bash
# 例: Chapter 01 のセットアップ
psql -f ~/course/chapter01-sql/setup.sql

# 例: 演習ファイルを実行
psql -f ~/course/chapter01-sql/practice/01_window_functions_basics.sql
```

---

## 接続情報（参考）

| 項目 | 値 |
|---|---|
| ホスト | `udemart-db`（bastion 内から）/ `localhost`（ホストPCから）|
| ポート | `5432` |
| データベース | `udemart` |
| ユーザー | `udemart` |
| パスワード | `udemart123` |

> bastion 内では環境変数が自動設定されるため、`psql` のみで接続できます。

---

## 環境を停止・削除する

```bash
# 停止（データは保持）
docker compose down

# データも含めて完全削除
docker compose down -v
```

---

## 動作要件

- Docker Desktop（Mac / Windows）または Docker Engine（Linux）
