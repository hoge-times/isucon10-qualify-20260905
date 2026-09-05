# ISUCON10 予選 (isuumo) アプリ構成マップ(Go)

作成日: 2026-09-05 / 採取元: i1 i2 i3 / 対象コミット: 9079187

> `isucon-app-map` スキルの成果物。**構造の記述であって施策の一覧ではない。**
> 「どこが遅いか」は計測結果(alp / pt-query-digest / pprof)を別途この地図に重ねて読む。

## 0. 前提

| 項目 | 値 | 出典 |
|---|---|---|
| アプリ名 | isuumo | `docs/kickoff.md` |
| webapp のパス | `/home/isucon/isuumo/webapp` | |
| Go のディレクトリ / エントリポイント | `go/` / `go/main.go`(979行) | |
| Go のバージョン | 1.14(`go.mod`)。**`go` コマンドは非ログインシェルの PATH に無い** | `app-map-raw/i1.md` |
| Web フレームワーク | echo v3.3.10 | `go/go.mod` |
| DB ドライバ | sqlx v1.2.0 + go-sql-driver/mysql v1.5.0 | `go/go.mod` |
| systemd ユニット(active) | `isuumo.go.service`(3台とも enabled / active) | `systemctl is-active` |
| DB の種類とバージョン | MySQL 5.7.42-0ubuntu0.18.04.1 | `app-map-raw/i1.md` |
| 初期化エンドポイント | `POST /initialize`(`go/main.go:252` → `go/main.go:287`) | |
| 制限時間(初期化) | 30 秒(超過で失格) | マニュアル |
| pprof | **未組み込み**(`net/http/pprof` の import 無し、`:6060` の LISTEN 無し) | `go/main.go` / `app-map-raw/*.md` |

## 1. サマリ

- **3台構成だが働いているのは i1 だけ。** i2 / i3 でも nginx・isuumo・mysqld が動いて LISTEN しているが、CPU 使用率上位に一切現れず、トラフィックが来ていない。
- **インデックスが主キーしか無い。** `chair` / `estate` とも 32,000 行で、検索系のすべての `WHERE`・`ORDER BY` 列(`price` / `height` / `width` / `depth` / `kind` / `color` / `stock` / `popularity` / `rent` / `door_width` / `door_height` / `latitude` / `longitude`)が未インデックス。
- **`POST /api/estate/nazotte` に上限なしの N+1。** バウンディングボックス内の物件を `LIMIT` 無しで全件取り、1件ずつ `ST_Contains` を投げている(`go/main.go:878-894`)。

## 索引

章ごとにファイルを分けている。**このファイルは入口で、詳細は各ファイルにある。**

| 章 | ファイル | 内容 | 図 |
|---|---|---|---|
| 2 | [稼働プロセス構成](02-processes.md) | 3台のうち i1 だけが働いている。i2 / i3 は遊休 | `flowchart` |
| 3 | [リクエストの流れ](03-request-flow.md) | nginx の location、静的ファイル配信、死んだ root 設定 | `flowchart` |
| 4 | [エンドポイント一覧](04-endpoints.md) | 15 本。加点対象2本と N+1 の位置 | `flowchart` |
| 5 | [データモデル](05-schema.md) | 2テーブル各 32,000 行。**主キー以外のインデックスが0本** | `erDiagram` |
| 6 | [初期化処理](06-initialize.md) | 30秒制限。**インデックスは 0_Schema.sql に書かないと消える** | `sequenceDiagram` |
| 7 | [設定の現状](07-settings.md) | nginx / MySQL / Go アプリの稼働値 | — |
| 8 | [外部依存](08-dependencies.md) | 外部通信なし。複数台化の障害は bind_address のみ | — |
| 9 | [触ってはいけない範囲](09-constraints.md) | 失格条件とスコア計算式 | — |

## 10. 目についた伸びしろ

**事実の列挙。優先順位はつけない。** 施策の決定は計測結果(alp / pt-query-digest / pprof)と突き合わせてから。

- **i2 / i3 にトラフィックが来ていない。** 3台とも nginx・isuumo・mysqld が起動して LISTEN しているが、CPU 上位に現れるのは i1 のみ(`app-map-raw/i2.md` / `i3.md`)。CPU 2コア × 3台のうち 2/3 が遊んでいる
- **主キー以外のインデックスが1本も無い。** 両テーブルともインデックス長 0 KB で、検索系の全条件が 32,000 行フルスキャン(`app-map-raw/db-schema.md`)
- **`innodb_buffer_pool_size` が既定の 128MB。** i1 の available メモリは 3.1G(`app-map-raw/i1.md`)
- **`POST /api/estate/nazotte` の N+1 に上限が無い。** BB 内の物件を `LIMIT` 無しで取得(`go/main.go:867`)し、1件ずつ `ST_Contains` を発行(`go/main.go:878-894`)。しかも②のクエリは `fmt.Sprintf` でポリゴン文字列を毎回埋め込んでいる(`go/main.go:882`)ためプリペアドが再利用されない
- **`db.SetMaxOpenConns(10)`**(`go/main.go:279`)。MySQL 側は `max_connections = 151`。`SetMaxIdleConns` は未設定で既定 2 のため、接続の張り直しが起きる
- **`e.Debug = true` / `log.DEBUG` / `middleware.Logger()` が全部有効**(`go/main.go:244-248`)。全リクエストが journald に書かれる
- **全ハンドラが `SELECT *`。** `description varchar(4096)` を毎回転送している(`go/main.go:324` ほか)
- **`features` の絞り込みが `LIKE CONCAT('%', ?, '%')`**(`go/main.go:481` / `:751`)。前方一致でないためインデックス不可
- **CSV 入稿がループ内 1 行ずつ INSERT**(`go/main.go:384` / `:681`)。**失敗・タイムアウトで一発失格**の経路
- **`gzip` が無効**(`i1-nginx.conf:46`)。`upstream` ブロックが無く `keepalive` も未設定
- **`long_query_time = 0` でスロークエリログが 104M**。計測には必要だが、最終ベンチ前に戻す必要がある
- **pprof が未組み込み。** チーム標準 Makefile の `make pprof` は `:6060` を叩く前提なので、現状は使えない
- **nginx の `server` 直下 `root` が実在しないパス**(`i1-nginx.conf:144`)。実害は無いが死んだ設定
- **`getLowPricedEstate` が全件を `ORDER BY rent` している**(`go/main.go:803`)。`chair` 側は `stock > 0` で絞るが `estate` 側は絞り込み条件なし

## 未確認

- **レギュレーション本文**(http://isucon.net/archives/54753430.html)は未取得。`docs/kickoff.md` の時点から変わらず未確認。マニュアルと矛盾する場合はマニュアルが優先
- **`go` コマンドが非ログインシェルの PATH に無い**(`app-map-raw/i1.md`)。ビルドはローカルで行い `make upload` で配るチーム標準の運用なので実害は無いが、サーバー上で `go build` する場合はフルパスが要る
- 採取時点で mysqld の CPU が 125%(i1)。採取の 2 分前(04:46)に mysqld と isuumo が起動しており、**直前に誰かが `make re` 相当を実行した直後の状態**と思われる。定常状態の値ではない
- `app-map-raw/*.err` は SSH の post-quantum 警告のみで、採取の失敗は無し
