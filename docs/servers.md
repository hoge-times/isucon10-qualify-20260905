# サーバー構成

**このファイルが現在のサーバー構成の唯一の正です。** 構成を変えたら、変えた人が同じ PR でここも更新してください(ワークスペースの `CLAUDE.md`「サーバー構成の記録(必須)」参照)。

最終更新: 2026-09-05 17:56 / iwashi623

## 現在の役割

<!-- ここは機械可読。report.sh などが読むので key=value の形を崩さないこと -->
```ini
bench=i1
app=i1
nginx=i1
db=i2 i3
hosts=i1 i2 i3
```

| キー | 意味 |
|---|---|
| `bench` | ベンチマーカーを実行するサーバー |
| `app` | アプリ(webapp)が動いているサーバー |
| `nginx` | nginx が動いているサーバー(**alp の採取先**) |
| `db` | MySQL が動いているサーバー(**pt-query-digest の採取先**) |
| `hosts` | いま使っているサーバー全部(役割が無い台も含む) |

複数台にまたがる場合は空白区切りで並べます(例 `app=i1 i2`)。`db=i2 i3` は **DB が 2 台に分かれている**という意味で、pt-query-digest は両方から採る必要があります。

## ホスト一覧

| alias | public IP | private IP | 現在の用途 |
|---|---|---|---|
| i1 | 54.168.109.155 | 172.31.0.109 | アプリ + nginx。ベンチもここで実行する。MySQL は停止済み |
| i2 | 43.206.232.245 | 172.31.0.196 | **MySQL 専有(chair テーブル)**。アプリと nginx は停止済み |
| i3 | 13.115.208.13 | 172.31.0.132 | **MySQL 専有(estate テーブル)**。アプリと nginx は停止済み |

2026-09-05 17:56 時点の `systemctl is-active isuumo.go.service nginx mysql` の実測:

| host | isuumo.go | nginx | mysql |
|---|---|---|---|
| i1 | active | active | inactive |
| i2 | inactive | inactive | active |
| i3 | inactive | inactive | active |

## DB のテーブル分割

`chair` と `estate` は JOIN もまたぐトランザクションも無いので、**テーブル単位で別サーバーに載せています**(PR: `perf/split-db-by-table`)。

| テーブル | ホスト | アプリ側の接続 |
|---|---|---|
| `chair` | i2 (172.31.0.196) | `chairDB` / `MYSQL_CHAIR_HOST` |
| `estate` | i3 (172.31.0.132) | `estateDB` / `MYSQL_ESTATE_HOST` |

- 接続先は **i1 の `/home/isucon/env.sh`** で指定します。このファイルは `isuumo.go.service` の `EnvironmentFile` で、**リポジトリ管理外**です。新しいサーバーに移すときは手で書いてください。

  ```sh
  MYSQL_HOST="172.31.0.196"        # 片方しか指定しなかった場合のフォールバック
  MYSQL_CHAIR_HOST="172.31.0.196"  # i2
  MYSQL_ESTATE_HOST="172.31.0.132" # i3
  ```

- `MYSQL_CHAIR_HOST` / `MYSQL_ESTATE_HOST` を消せば両方 `MYSQL_HOST` に落ちるので、**単一 DB 構成に戻せます**。`initialize` も 2 つのホストが同じなら従来どおり 1 回で流します。
- `POST /initialize` は `0_Schema.sql`(両テーブルを作る)を**両ホストに**流し、データは担当テーブルのぶんだけ入れます。使わない側のテーブルは空のまま残ります。
- どちらの MySQL も `bind-address = 0.0.0.0` で、リモート接続用に `isucon'@'%'` を作ってあります。AWS の Security Group は VPC 内の 3306 を通すので変更不要です。

## 注意

- **`Makefile` の `bench` / `pbnalp1` は `i1` 直値**です。web ホストを変えたらここも直してください。
- `make prepare` は web ホストで `make re`(アプリ + nginx)、**両方の DB ホストで `make dbre`**(MySQL)を叩きます。
- ログの採取先が分かれています。**alp は i1、pt-query-digest は i2 と i3 の両方**。

  ```
  make pbnalp1     # alp (i1 の nginx アクセスログ)
  make pbpt2       # pt  (i2 = chair のスロークエリログ)
  make pbpt3       # pt  (i3 = estate のスロークエリログ)
  ```

- `upload2` / `upload3` は現構成では使いません。i2 / i3 はどちらも MySQL 専有でアプリを動かしていません。
- **ベンチは他のメンバーと同時に回さないこと。** 走行中に別のベンチが `POST /initialize` を叩くと DB が drop され、走っているほうが 500 を出して落ちます(2026-09-05 17:50 に実際に踏みました)。回す前に `ssh i1 'ps -ef | grep [b]ench'` で確認してください。

## 変更履歴

| 日時 | 変更 | 実施者 |
|---|---|---|
| 2026-09-05 12:30 | キックオフ。全役割を i1 に置き、i2 / i3 は未使用 | iwashi623 |
| 2026-09-05 17:0x | MySQL を i2 に分離し、i1 を web 専有にする(PR #28) | (チーム) |
| 2026-09-05 17:40 | 現状を確認して本ファイルを新規作成。i3 は別メンバーが検証用に使用中 | iwashi623 |
| 2026-09-05 17:56 | i3 の nginx / アプリを止め、**estate の MySQL 専有機**にする。chair は i2 に残す(score 7351 → 14259) | iwashi623 |
