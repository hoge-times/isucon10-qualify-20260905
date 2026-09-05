## 8. 外部依存 / 複数台構成の障害

- **外部 API / モック（叩き先・ポート）**: **無し。** `go/main.go` に `http.Client` の使用は 0 件。外部への HTTP 通信は発生しない。ISUCON9 のような外部決済 API モックに相当するものは存在しない。
- **外部プロセスの起動**: **有り。** `POST /initialize` が `exec.Command("bash", "-c", "mysql … < <file>")` を 3 回起動する（`go/main.go:296-305`）。`mysql` クライアントがローカルに存在することと、`WorkingDirectory` が `/home/isucon/isuumo/webapp/go` であることに依存する。
- **ファイル保存先（複数台化で壊れるもの）**:

  | 対象 | 場所 | 複数台化したときの影響 |
  |---|---|---|
  | CSV 入稿ファイル | **保存しない。** `c.FormFile` で受けて `csv.ReadAll()` でメモリ展開し、DB に INSERT したら破棄（`go/main.go:342-356`, `:640-654`） | 影響なし |
  | 静的画像 | `/www/data/images`（401MB のうち chair 275MB / estate 126MB）。nginx が配信 | **アプリの外**。台を増やすなら全台に配る必要がある。DB の `thumbnail` 列は `/images/chair/<hash>.png` のようなパス文字列を持つだけで、バイナリは DB に入っていない |
  | 検索条件マスタ | `webapp/fixture/chair_condition.json` / `estate_condition.json`。アプリが起動時に読む | **全台に同じものが必要。** 無いと `os.Exit(1)` で起動失敗（`go/main.go:229, 236`） |
  | 初期化 SQL | `webapp/mysql/db/*.sql`（27 MB）。`initialize` を受けた台の**ローカル**を読む | **アプリと DB を別台に分けると、`initialize` を受ける台に SQL ファイルと `mysql` クライアントが必要**。かつ `-h` で DB 台を指すので `bind_address` と権限も要変更 |

- **プロセスメモリに持っている状態（`map` キャッシュ / カウンタ / セッション）**:
  - `chairSearchCondition` / `estateSearchCondition` の 2 変数のみ（`go/main.go:28-29`）。`init()`（`go/main.go:225-239`）で JSON を読み込むだけの**読み取り専用**で、リクエスト処理中に書き換える箇所は無い。
  - **カウンタ・セッション・ログイン状態・`sync.Mutex` / `sync.Map` はいずれも無い。** アプリは完全にステートレスで、**水平分割の障害になるものが無い。**
  - 注意点として、この 2 変数は `/initialize` で再読み込みされない（[章6](06-initialize.md)）。
- **アプリ内での ID 採番**: **無し。** `chair.id` / `estate.id` はダミーデータ SQL および CSV 入稿の値をそのまま使う（`go/main.go:367`, `:665`）。`AUTO_INCREMENT` も無い（`mysql/db/0_Schema.sql`）。**採番の競合を気にせず複数台に分散できる。**
- **cron / タイマー**: アプリ由来のものは無し。`isucon` ユーザーの crontab は 3 台とも空。システム側に Ubuntu 標準の `mdadm` と `popularity-contest` があるのみ（`app-map-raw/i{1,2,3}.md`）。アプリ内の `time.Sleep` / ポーリングも 0 件。
- **認証・セッション**: 無し。`POST /api/chair/buy/:id` と `POST /api/estate/req_doc/:id` は `email` を受け取るが、**検証も保存もしていない**（`go/main.go:534-544`, `:909-919`）。
- **複数台構成にするときの具体的な障害**:
  1. **MySQL が `bind_address = 127.0.0.1`**（3 台とも）で、ユーザー権限も `isucon@localhost` のみ。他台からの接続は現状不可。
  2. **`/initialize` の SQL ファイル参照が相対パス**（`../mysql/db`）なので、実行台に webapp ディレクトリが要る。
  3. **静的画像 401MB** をどの台の nginx が返すか決める必要がある（DB には入っていないので配布かリバースプロキシで解決）。
  4. アプリ自体はステートレスなので、上記 3 点を除けば台数を増やす障害は無い。

---

[← 索引に戻る](README.md) ｜ [次: 触ってはいけない範囲 →](09-constraints.md)
