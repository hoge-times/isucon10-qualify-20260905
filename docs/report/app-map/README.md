# ISUCON10 予選（isuumo）アプリ構成マップ（Go）

作成日: 2026-09-05 / 採取元: `i1 i2 i3` / 対象コミット: `2a89c7b`

> `isucon-app-map` スキルの成果物。**構造の記述であって施策の一覧ではない。**
> 「どこが遅いか」は計測結果（alp / pt-query-digest / pprof）を別途この地図に重ねて読む。
> 生ログは `app-map-raw/`（`.gitignore` 済み・commit しない）。

## 0. 前提

| 項目 | 値 | 出典 |
|---|---|---|
| アプリ名 | ISUUMO（`isuumo`） | `docs/kickoff.md` |
| webapp のパス | `/home/isucon/isuumo/webapp`（リポジトリルートは `/home/isucon/isuumo`） | `docs/kickoff.md` |
| Go のディレクトリ / エントリポイント | `/home/isucon/isuumo/webapp/go` / `go/main.go`（979 行、単一ファイル） | `isuumo.go.service` |
| Go のバージョン | **未確認**（3 台とも `go` が PATH に無い）。`docs/kickoff.md` の記載は 1.14.7、`go.mod:3` は `go 1.14` | `app-map-raw/i{1,2,3}.md` |
| Web フレームワーク | **echo v3**（`v3.3.10+incompatible`） | `go/go.mod:10`、`go/main.go:243` |
| DB ドライバ | **sqlx v1.2.0** + `go-sql-driver/mysql v1.5.0` | `go/go.mod:8-9` |
| systemd ユニット名（active） | `isuumo.go.service`（3 台とも enabled / active。他言語ユニットは全台 disabled / inactive） | `systemctl is-active` |
| DB の種類とバージョン | MySQL 5.7.42-0ubuntu0.18.04.1、DB 名 `isuumo` | `app-map-raw/db-schema.md` |
| 初期化エンドポイント | `POST /initialize`（`go/main.go:252`、実装 `:287`） | |
| 制限時間（初期化） | **30 秒**（超過で失格） | `docs/isucon10_qualify_manual.md` |
| pprof | **未組み込み**（`net/http/pprof` の import なし、3 台とも `:6060` 未 LISTEN） | `go/main.go:3-21`、`app-map-raw/i{1,2,3}.md` |

## 1. サマリ

- **3 台すべてで nginx + `isuumo`(:1323) + MySQL が同一構成で稼働しているが、トラフィックが入るのは i1 のみ。i2 / i3 は 1 リクエストも受けていない完全な遊休。** MySQL は 3 台とも `bind_address = 127.0.0.1` で他台から繋げず、権限も `isucon@localhost` のみ。
- **`chair` / `estate` の 2 テーブル・各 32,000 行に対し、セカンダリインデックスが 1 本も存在しない（インデックス長 0 KB）。** `id` 以外のすべての検索・整列（`popularity` / `price` / `rent` / `stock` / `door_*` / `latitude` / `longitude` / `features` の LIKE 中間一致）がフルスキャン + filesort になる。
- **構造上の目立った問題は 3 つ**: `POST /api/estate/nazotte` が LIMIT なしの矩形検索 + 1 件ずつの `ST_Contains`（`go/main.go:867`, `:883`）、Go アプリが `e.Debug = true` かつ `middleware.Logger()` 有効で全リクエストをログ出力（`:244-248`）、`SetMaxOpenConns(10)` に対し `SetMaxIdleConns` 未設定（既定 2、`:279`）。アプリはステートレスで ID 採番も無く、**水平分割の障害は「DB の bind_address」「initialize の SQL 相対パス」「静的画像 401MB の配置」の 3 点だけ。**

## 索引

章ごとにファイルを分けている。**このファイルは入口で、詳細は各ファイルにある。**

| 章 | ファイル | 内容 | 図 |
|---|---|---|---|
| 2 | [稼働プロセス構成](02-processes.md) | 台ごとに何が動いていて、どこにトラフィックが来ているか | `flowchart` |
| 3 | [リクエストの流れ](03-request-flow.md) | nginx の location から アプリ / 静的ファイル / DB まで | `flowchart` |
| 4 | [エンドポイント一覧](04-endpoints.md) | メソッド / パス / ハンドラ / クエリ / N+1（全 15 本） | `flowchart` ×2 |
| 5 | [データモデル](05-schema.md) | テーブル / 行数 / インデックス / 欠落している検索条件 | `erDiagram` |
| 6 | [初期化処理](06-initialize.md) | 何を再現しているか、変更時に守るべき整合性 | `sequenceDiagram` |
| 7 | [設定の現状](07-settings.md) | nginx / DB / Go アプリの**稼働値** | — |
| 8 | [外部依存](08-dependencies.md) | 外部 API / ファイル / プロセスメモリの状態 | — |
| 9 | [触ってはいけない範囲](09-constraints.md) | レギュレーション由来の失格条件 | — |

## 10. 目についた伸びしろ

**事実の列挙にとどめる。優先順位はつけない。** 施策の決定は計測結果（alp / pt-query-digest / pprof）と突き合わせてから行う。

- **セカンダリインデックスが 0 本。** `chair` / `estate` ともインデックス長 0 KB、`CREATE TABLE` にも `PRIMARY KEY` 以外の定義が無い（`app-map-raw/db-schema.md`、`mysql/db/0_Schema.sql`）。WHERE / ORDER BY で使われている列は[章5](05-schema.md)に列名で一覧化した。
- **i2 / i3 が完全な遊休。** プロセスは i1 と同一構成で動いているがトラフィックが 0（[章2](02-processes.md)）。アプリはステートレス・ID 採番なし・セッションなしなので分散の障害が少ない（[章8](08-dependencies.md)）。
- **`POST /api/estate/nazotte` の N+1。** `go/main.go:867` の矩形検索に LIMIT が無く、`go/main.go:883` で矩形内の件数ぶん `ST_Contains` を 1 件ずつ発行する。50 件への切り詰めはループ後（`:898-902`）なのでクエリ回数は減らない。`docs/kickoff.md` にこのエンドポイントのタイムアウトが記録されている。
- **`estate` に空間インデックスが無い。** `latitude` / `longitude` は `DOUBLE` の別カラムで、`GEOMETRY` 型の列も SPATIAL インデックスも存在しない（`mysql/db/0_Schema.sql`）。
- **CSV 入稿が 1 行ずつの INSERT。** `postChair`（`go/main.go:384`）と `postEstate`（`go/main.go:681`）が for ループ内で `tx.Exec` を回す。ただし**この 2 本は失敗すると `(critical error)` で一発失格**（[章9](09-constraints.md)）。
- **Go アプリのデバッグ設定が本番のまま。** `e.Debug = true`（`go/main.go:244`）、`e.Logger.SetLevel(log.DEBUG)`（`:245`）、`middleware.Logger()`（`:248`）で全リクエストが journald に流れる。i1 で `systemd-journald` が 272 MB とメモリ最大のプロセスになっている（[章2](02-processes.md)）。
- **DB コネクションプールが既定寄り。** `SetMaxOpenConns(10)`（`go/main.go:279`）だけ設定され、`SetMaxIdleConns`（既定 2）と `SetConnMaxLifetime` は未設定。MySQL 側の `max_connections` は 151 で余っている。
- **DSN にパラメータが 1 つも無い。** `interpolateParams` / `parseTime` / `charset` / `loc` すべて未指定（`go/main.go:221`）。
- **MySQL がほぼ Ubuntu 既定値。** `innodb_buffer_pool_size` 128 MB（実メモリ 3.8 GB の 3.4%）、`innodb_flush_log_at_trx_commit=1`、`innodb_io_capacity=200`（[章7](07-settings.md)）。
- **nginx が gzip OFF・upstream keepalive なし・静的ファイルのキャッシュヘッダなし。** `/www/data` は 401 MB（うち画像 401 MB 相当）。ただしベンチは静的ファイルを叩かない（[章9](09-constraints.md)）。
- **bot 判定が実装されていない。** マニュアルは 10 パターンの UA への 503 返却を明示的に許可しているが、nginx にもアプリにも UA を見る箇所が無い（[章4](04-endpoints.md) / [章9](09-constraints.md)）。
- **pprof が未組み込み。** チーム標準 Makefile の `pprof` ターゲットは `:6060` がある前提なので現状では使えない。
- **検索系は 1 リクエストで 2 クエリ。** `searchChairs` / `searchEstates` が `COUNT(*)` と本体 `SELECT` を別々に発行する（`go/main.go:511`/`:519`、`:779`/`:787`）。
- **`features` の絞り込みが中間一致 LIKE。** `LIKE CONCAT('%', ?, '%')`（`go/main.go:481`, `:751`）でインデックスが効かない形。
- **i1 のスロークエリ設定が実行時設定のみ。** `slow_query_log=ON` / `long_query_time=0` は `SET GLOBAL` 由来で、`mysql/mysql.conf.d/mysqld.cnf:76-78` はコメントアウトのまま。**mysqld 再起動で OFF に戻り pt-query-digest が空になる**（[章7](07-settings.md)）。
- **nginx の `server` 直下の `root` が実在しないパス**（`/home/isucon/isucon10-qualify/webapp/public`）。`location /` の `root /www/data` に上書きされているため実害は無いが、設定を読むときに誤読しやすい（[章3](03-request-flow.md)）。

## 未確認

- **Go ランタイムのバージョン。** 3 台とも `go` コマンドが PATH に無く、`go version` が採れなかった。`docs/kickoff.md` の記載は 1.14.7、`go/go.mod:3` は `go 1.14`。
- **`POST /initialize` の実所要時間。** 27 MB の SQL を外部 `mysql` プロセスで流しているが、30 秒制限に対する余裕は未計測。
- **`webapp/fixture/chair_condition.json` / `estate_condition.json` の中身。** `go/main.go:225-239` で読み込んでいることは確認したが、range の実際の値と件数は未確認。
- **ベンチマーカーが各エンドポイントをどの比率で叩くか。** alp での実測が必要。
- **レギュレーション本文**（http://isucon.net/archives/54753430.html）は未取得。マニュアルと矛盾する場合はマニュアルが優先（`docs/kickoff.md`）。
- `app-map-raw/*.err` は**1 つも生成されなかった**（3 台 + DB とも採取は完走）。
