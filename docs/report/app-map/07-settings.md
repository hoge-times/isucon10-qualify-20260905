## 7. 設定の現状

**稼働値を書く。設定ファイルの記述ではない。**

### nginx（`app-map-raw/i{1,2,3}-nginx.conf` = `nginx -T` の展開結果より）

3 台とも設定は完全に同一（`diff` で差分ゼロ）。

| 項目 | 現在値 | 備考 |
|---|---|---|
| `worker_processes` | `auto` | CPU 2 コアなので worker は 2。i2 の採取では nginx worker が 3 プロセス見えている（master 1 + worker 2） |
| `worker_connections` | `1024` | |
| `gzip` | **OFF**（`#gzip on;` とコメントアウト） | `nginx/nginx.conf:42` |
| `keepalive`（upstream） | **未設定**。`upstream` ブロック自体が無く、`proxy_pass http://localhost:1323` を直書き | アプリへの接続は毎回張り直し。`proxy_http_version` / `Connection` ヘッダの指定も無し |
| `keepalive_timeout`（クライアント側） | `65` | `nginx/nginx.conf:40` |
| `sendfile` | `on` | |
| `tcp_nopush` | **OFF**（コメントアウト） | |
| `access_log` の形式 | **LTSV**（`log_format ltsv`、`nginx/nginx.conf:22-36`） | alp で集計可能。`reqtime`（`$request_time`）と `apptime`（`$upstream_response_time`）を含む |
| `access_log` の出力先 | `/var/log/nginx/access.log` | 走行のたびにローテートしないと alp の集計が混ざる |
| `error_log` | `/var/log/nginx/error.log warn` | |
| 静的ファイルのキャッシュヘッダ | **未設定**（`expires` / `Cache-Control` の指定なし） | `/www/data` 401MB を素で返している |
| `open_file_cache` | **未設定** | |
| `server` 直下の `root` | `/home/isucon/isucon10-qualify/webapp/public` — **実在しないパス** | `location /` の `root /www/data` に上書きされる |

### DB（`app-map-raw/db-schema.md` / `app-map-raw/i{1,2,3}-mysql.txt` の稼働値より）

MySQL 5.7.42-0ubuntu0.18.04.1。**設定ファイル（`mysql/mysql.conf.d/mysqld.cnf`）はほぼ Ubuntu 既定のままで、下記はすべてデフォルト値。**

| 項目 | 現在値 | 備考 |
|---|---|---|
| `innodb_buffer_pool_size` | **134217728（128 MB）** | 実メモリ 3.8 GB に対して 3.4%。データ長は 2 テーブル合計で約 28 MB なので現時点では収まるが、既定値のまま |
| `innodb_buffer_pool_instances` | `1` | |
| `innodb_flush_log_at_trx_commit` | **`1`** | 毎コミットで fsync。緩めると永続化の失格条件（追試での再起動チェック）に関わるので注意 |
| `innodb_flush_method` | 空（未設定） | |
| `innodb_log_file_size` | `50331648`（48 MB） | |
| `innodb_io_capacity` | `200` | NVMe に対して既定値 |
| `max_connections` | `151` | アプリ側の `SetMaxOpenConns(10)` × 3 台でも 30 なので上限には当たらない |
| `bind_address` | **`127.0.0.1`** | **他の台から接続できない。** DB を別台に分ける場合はここと権限（`isucon@localhost` のみ）の両方を変える必要がある |
| `query_cache_type` | `OFF` | |
| `sync_binlog` / `log_bin` | `1` / `OFF` | バイナリログ無効なので `sync_binlog` は効いていない |
| `character_set_server` | `utf8mb4` | |
| `table_open_cache` / `thread_cache_size` | `2000` / `8` | |
| `tmp_table_size` / `max_heap_table_size` | 16 MB / 16 MB | filesort / 一時テーブルが多い構成なので効いてくる |
| `slow_query_log` | **i1 のみ ON / i2・i3 は OFF** | |
| `long_query_time` | **i1 のみ `0.000000` / i2・i3 は `10.000000`** | |
| `slow_query_log_file` | i1: `/var/log/mysql/slow.log` | i2/i3 は既定の `/var/lib/mysql/<host>-slow.log` |

**i1 のスロークエリ設定は `SET GLOBAL` による実行時設定で、設定ファイルには書かれていない。** `mysql/mysql.conf.d/mysqld.cnf:76-78` では `slow_query_log` / `slow_query_log_file` / `long_query_time` の 3 行がすべてコメントアウトされたまま。**mysqld を再起動すると OFF に戻り、pt-query-digest が空になる。**

### Go アプリ

| 項目 | 現在値 | 場所 |
|---|---|---|
| `SetMaxOpenConns` | **`10`**（ハードコード） | `go/main.go:279` |
| `SetMaxIdleConns` | **未設定**（`database/sql` 既定の 2） | — |
| `SetConnMaxLifetime` | **未設定** | — |
| DSN | `<user>:<pass>@tcp(<host>:<port>)/<dbname>` — **パラメータ一切無し**（`interpolateParams` / `parseTime` / `charset` / `loc` すべて未指定） | `go/main.go:221` |
| 接続の張り方 | `sqlx.Open` のみ（遅延接続。`Ping` を呼んでいない） | `go/main.go:222` |
| デバッグフラグ | **`e.Debug = true`** | `go/main.go:244` |
| ログレベル | **`log.DEBUG`** | `go/main.go:245` |
| ログミドルウェア | **`middleware.Logger()` 有効**（全リクエストを標準出力へ = journald へ） | `go/main.go:248` |
| Recover ミドルウェア | 有効 | `go/main.go:249` |
| `http.Server` のタイムアウト | **未設定**（`e.Start()` を使っており `ReadTimeout` / `WriteTimeout` / `IdleTimeout` の指定なし） | `go/main.go:284` |
| listen ポート | `:1323`（env `SERVER_PORT` で上書き可） | `go/main.go:283-284` |
| `GOMAXPROCS` | 明示指定なし（= CPU コア数 2） | — |
| pprof | **未組み込み**（`net/http/pprof` の import なし、`:6060` も未 LISTEN） | `go/main.go:3-21` |

**チーム標準 Makefile の `pprof` ターゲットは `:6060` がある前提**なので、現状では使えない。

### DB 接続情報の供給元

`isuumo.go.service` の `EnvironmentFile=/home/isucon/env.sh`:

```
MYSQL_HOST="127.0.0.1"
MYSQL_PORT=3306
MYSQL_USER=isucon
MYSQL_DBNAME=isuumo
MYSQL_PASS=isucon
```

`go/main.go:201-209` の既定値と完全に一致しているため、`env.sh` を消してもアプリは同じ接続先で動く。

### 設定ファイルの Git 管理状態

`/etc/nginx` → `/home/isucon/isuumo/webapp/nginx`、`/etc/mysql` → `/home/isucon/isuumo/webapp/mysql` の symlink 化が 3 台とも完了済み（`isucon-repo-setup` 済み）。設定変更はリポジトリ側を編集して配布する。

---

[← 索引に戻る](README.md) ｜ [次: 外部依存 →](08-dependencies.md)
