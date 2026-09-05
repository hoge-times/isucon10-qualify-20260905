## 7. 設定の現状

**稼働値。設定ファイルの記述ではない。**

### nginx(`app-map-raw/i1-nginx.conf`、3台とも md5 一致)

| 項目 | 現在値 | 備考 |
|---|---|---|
| `worker_processes` | `auto`(= 2、CPU コア数) | `:3` |
| `worker_connections` | `1024` | `:10` |
| `gzip` | **コメントアウト(無効)** | `:46` `#gzip on;` |
| `keepalive`(upstream) | **upstream ブロック自体が無い** | `proxy_pass` に直書き |
| `keepalive_timeout` | `65` | `:44`(クライアント側) |
| `access_log` の形式 | **LTSV**(`ltsv` 定義は `:23`、適用は `:39`) | キックオフ済み。alp で集計可能 |
| ログサイズ | `/var/log/nginx` 5.9M | |

### MySQL(`app-map-raw/db-schema.md` / `i1-mysql.txt`)

| 項目 | 現在値 | 備考 |
|---|---|---|
| `innodb_buffer_pool_size` | **134217728 (128MB)** | 既定値のまま。**実メモリ 3.8G / available 3.1G に対して極端に小さい** |
| `innodb_buffer_pool_instances` | 1 | |
| `innodb_flush_log_at_trx_commit` | **1** | 永続化は失格条件なのでレギュレーション確認のうえで判断 |
| `innodb_log_file_size` | 50331648 (48MB) | |
| `innodb_io_capacity` | 200 | |
| `max_connections` | 151 | アプリ側は 10 しか開かない(下記) |
| `table_open_cache` | 2000 | |
| `tmp_table_size` / `max_heap_table_size` | 16MB / 16MB | |
| `query_cache_size` / `query_cache_type` | 16MB / **OFF** | サイズは確保されているが type が OFF |
| `slow_query_log` | **ON** | キックオフの `make mrestart` 済み |
| `long_query_time` | **0.000000** | 全クエリ記録。**ログサイズ `/var/log/mysql` が既に 104M** |
| `bind_address` | **127.0.0.1** | 他の台からは接続できない |
| `log_bin` / `sync_binlog` | OFF / 1 | バイナリログ無効 |

**接続元の許可**: `mysql.user` は `isucon@localhost` など**すべて `localhost` のみ**。DB を分離するには `bind_address` と権限の両方を変える必要がある。

### Go アプリ(`go/main.go`)

| 項目 | 現在値 | 場所 |
|---|---|---|
| `SetMaxOpenConns` | **10** | `go/main.go:279` |
| `SetMaxIdleConns` | **未設定**(既定 2) | — |
| `SetConnMaxLifetime` | **未設定** | — |
| デバッグフラグ | **`e.Debug = true`** | `go/main.go:244` |
| ログレベル | **`log.DEBUG`** | `go/main.go:245` |
| ログミドルウェア | **`middleware.Logger()` 有効** | `go/main.go:248` |
| `middleware.Recover()` | 有効 | `go/main.go:249` |
| `http.Server` のタイムアウト | **未設定**(`e.Start(":1323")`) | `go/main.go:283` |
| 待受ポート | `SERVER_PORT` 環境変数、既定 `1323` | `go/main.go:282` |
| pprof | **未組み込み** | — |


---

[← 索引に戻る](README.md) ｜ [次: 外部依存 →](08-dependencies.md)
