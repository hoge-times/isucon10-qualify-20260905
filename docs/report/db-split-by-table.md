# DB のテーブル分割 (chair = i2 / estate = i3)

対象: `isucon10-qualify-20260905` / 2026-09-05
前提: [server-split.md](server-split.md)(i1 = web / i2 = MySQL に分けた段階)

---

## 0. 要約

DB を 1 台で持っていたのを、**`chair` を i2 / `estate` を i3** に分けた。**score 7351 → 14259 (+6908 / 1.94 倍)**。

## 1. なぜ分けたか

分割前の実測(負荷区間 56 秒平均、各ホスト 2 vCPU):

| | i1 (web) | i2 (db) |
|---|---:|---:|
| ホスト CPU 使用中 | 37.4% | **98.1%**(idle 1.9%) |
| iowait | 0.1% | 0.2% |
| 主プロセス | `bench` 34.0% / `isuumo` 23.9% / `nginx` 6.3% | `mysqld` **193.8% / 200%** |

**i2 が完全に飽和**していた。`wa` が 0.2% なので IO 待ちではなく純粋な CPU 律速。一方 i1 は 37.4% で、しかもそのうち 34.0% はベンチ自身なので web 側には余裕があった。

**bot への 503 は既に入っている**状態での数字(ベンチ中に 503 を 1990 件返している)。安いほうの手は打ち切った後で、残っている壁が DB の CPU だった。

### 分割して割に合うかの事前確認

pt-query-digest は MISC が 60.7% を占めて上位 20 件では判断できなかったため、**スロークエリログ 78k 件全体をテーブル別に集計**した。

| 対象 | Exec 時間 | 割合 | 件数 | Rows_examined |
|---|---:|---:|---:|---:|
| `chair` | 166.1s | **48.9%** | 29,572 | 64.8M |
| `estate` | 169.3s | **49.9%** | 39,567 | 113.9M |
| その他 (COMMIT 等) | 4.0s | 1.2% | 2,352 | — |

分割後の上限は重い側で決まるので、偏っていれば期待外れになる。**ほぼ 50:50** だったので割に合うと判断した。

さらに `go/main.go` を確認すると、**chair と estate をまたぐ JOIN もトランザクションも無い**(全 SQL が片側のテーブルだけ、`db.Begin()` の 2 箇所も各テーブルの CSV 一括 INSERT)。`GET /api/recommended_estate/:id` も「chair を引く → estate を引く」の 2 クエリなので、DSN を 2 本に分けるだけで割れる。

## 2. 実際にやったこと

### アプリ (i1)

- `db` を `chairDB` / `estateDB` の 2 本にした。接続先は `MYSQL_CHAIR_HOST` / `MYSQL_ESTATE_HOST`。**未設定なら `MYSQL_HOST` に落ちる**ので単一構成に戻せる。
- `initialize` は `0_Schema.sql`(両テーブルを作る)を両ホストに流し、データは担当テーブルのぶんだけ入れる。27MB の dump を 2 ホストに流すので**ホスト単位で並列化**した。2 つのホストが同じなら従来どおり 1 回で流す。
- `/home/isucon/env.sh` に `MYSQL_CHAIR_HOST` / `MYSQL_ESTATE_HOST` を追記(**リポジトリ管理外**)。

### i3 (estate 専有にする)

- `nginx` と `isuumo.go.service` を stop + disable。
- `/etc/mysql` はリポジトリへの symlink なので、`git pull` + `systemctl restart mysql` で `bind-address = 0.0.0.0` が反映される。
- リモート接続用の `isucon'@'%'` を作成。Security Group は VPC 内の 3306 を通していたので変更不要。

### Makefile

- `db_host` を `chair_db_host` / `estate_db_host` に分け、`prepare` が**両方の MySQL を再起動**するようにした。
- `mrestart` に **MySQL の起動待ち**(`mysqladmin ping`)を入れた。理由は 4 節。

## 3. 結果

| | i1 (web) | i2 (chair) | i3 (estate) |
|---|---:|---:|---:|
| ホスト CPU 使用中 | 73.9% | **94.7%** | **94.0%** |
| 主プロセス | `bench` 68.5% / `isuumo` 55.4% / `nginx` 12.2% | `mysqld` **187.7%** | `mysqld` **187.4%** |
| slow log Exec time | — | 326s (64.4k queries) | 257s (81.0k queries) |

**187.7% と 187.4% でほぼ均等**。事前に見た 48.9 : 49.9 のとおりに割れた。同じ 1 分間にこなした DB の仕事は 339.5s → 583s で約 1.7 倍。

`initialize` は並列化のぶん **2.29s → 1.46s** に短縮。

## 4. 踏んだ罠

- **`make prepare` が途中で止まっていた。** `systemctl restart mysql` の直後はまだ接続を受け付けないことがあり、続く `set global slow_query_log = 1` が失敗して make が中断する。`prepare` は web → chair DB → estate DB の順なので、**estate DB の `dbre` が実行されないまま**ベンチが走り、起動途中の MySQL に当たって `initialize` が 500 で落ちた。`mysqladmin ping` が通るまで待つようにした。
- **他のメンバーのベンチと衝突した。** 走行中に別のベンチが `POST /initialize` を叩き、両 DB が drop されて `Table 'isuumo.chair' doesn't exist` が大量に出た。回す前に `ssh i1 'ps -ef | grep [b]ench'` で確認すること。

## 5. 次にやること

DB は i2 / i3 とも 94% で、また両方が壁になりつつある。ただし **i1 も 73.9% まで上がった**(うち `bench` が 68.5%。本戦ではベンチは外部なので、実際の web 側の余裕はもう少しある)。

1. **検索クエリのバケット化。** `Rows_examined` は i2 が 121.6M、i3 が 224.5M と依然として巨大。バケット ID の生成列 + 複合インデックスで filesort と OFFSET スキャンを消す([mysql-index-plan.md](mysql-index-plan.md) の段 B の先)。負荷を移すのではなく減らす手はこれが残っている。
2. **`db.SetMaxOpenConns(10)` の見直し。** いまは chair / estate それぞれ 10。mysqld が 187% まで出ているので CPU が天井だが、バケット化で 1 クエリが軽くなったら接続数が効いてくる。
3. **アプリの複数台化。** i1 が 73.9% なので、次に web が壁になったら考える。ただし空いている台はもう無い。
