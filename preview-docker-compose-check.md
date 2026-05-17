# 購入前プレビュー: Docker Compose 動作確認

この講座は Docker Compose を使って PostgreSQL と踏み台サーバーを起動します。
購入前に、以下の手順が自分のPCで実行できることを確認してください。

この確認が通れば、講座本編の実習環境も基本的に問題なく動かせます。

---

## このプレビューで確認する環境

| 項目 | バージョン / 条件 |
|---|---|
| PostgreSQL | Docker公式イメージ `postgres:16`（検証時: PostgreSQL 16.14） |
| Docker Compose | v2系 |
| 踏み台サーバー | Ubuntu 22.04 ベース |
| 使用ポート | `5432`, `2222` |

---

## 対象者

この講座は、以下を満たす方を対象にしています。

- Docker Desktop をインストール済み、またはインストールできる
- ターミナル、PowerShell、コマンドプロンプトのいずれかを開ける
- `docker compose up` / `docker compose down` を実行できる
- ポート競合が起きたときに、他のコンテナを停止できる

PostgreSQL のローカルインストールは不要です。

---

## 1. Docker Desktop を起動する

Docker Desktop を起動し、以下のコマンドが通ることを確認します。

```bash
docker --version
docker compose version
```

期待する状態:

- `Docker version ...` が表示される
- `Docker Compose version ...` が表示される
- エラーにならない

---

## 2. 使用ポートを確認する

この講座では、共通環境で以下のポートを使います。

| ポート | 用途 |
|---|---|
| 5432 | PostgreSQL |
| 2222 | 踏み台サーバー SSH |

macOS / Linux:

```bash
lsof -i :5432
lsof -i :2222
```

Windows:

```powershell
netstat -an | findstr "5432"
netstat -an | findstr "2222"
```

何も表示されなければ、そのポートは空いています。
すでに別のコンテナやPostgreSQLが使っている場合は、講座環境の起動前に停止してください。

---

## 3. 講座環境を起動する

Udemyの購入前プレビューに添付された確認用ファイルを展開し、そのディレクトリに移動して起動します。

```bash
docker compose up -d --build
```

初回は PostgreSQL イメージの取得と bastion イメージのビルドがあるため、数分かかることがあります。

---

## 4. 起動確認をする

```bash
docker compose ps
```

期待する状態:

```text
udemart-db        Up
udemart-bastion   Up
```

表示形式は Docker のバージョンによって多少異なります。
重要なのは、`udemart-db` と `udemart-bastion` の2つが起動していることです。

---

## 5. 踏み台サーバーにSSH接続する

```bash
ssh student@localhost -p 2222
```

パスワード:

```text
student123
```

ログインできたら、次のコマンドで PostgreSQL に接続します。

```bash
psql
```

期待する状態:

```text
udemart=#
```

ここまで表示できれば、講座の実習環境は動作しています。

終了するには以下を実行します。

```sql
\q
```

SSHから抜けるには以下を実行します。

```bash
exit
```

---

## 6. 動作確認用SQLを実行する

ローカルのターミナルから直接確認する場合:

```bash
docker exec udemart-db psql -U udemart -d udemart -c "SELECT version();"
```

期待する状態:

- PostgreSQL 16 のバージョン情報が表示される

---

## 7. 確認後に環境を停止する

プレビュー確認が終わったら、コンテナを停止します。

```bash
docker compose down -v
```

このコマンドは講座環境のデータも削除します。
本編開始前の動作確認では削除して問題ありません。

---

## プレビュー動画で伝えること

動画では、以下をそのまま見せると購入前の不安を減らせます。

1. Docker Desktop が起動していること
2. `docker compose version` が成功すること
3. `docker compose up -d --build` で2コンテナが起動すること
4. `ssh student@localhost -p 2222` で踏み台に入れること
5. `psql` で `udemart=#` が表示されること
6. `docker compose down -v` で片付けられること

ここまでできる方であれば、この講座の実習を進められます。
