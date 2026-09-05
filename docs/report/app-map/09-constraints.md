## 9. 触ってはいけない範囲

出典: `docs/isucon10_qualify_manual.md`（レギュレーションと矛盾する場合はマニュアルが優先）と `docs/kickoff.md`。

### 一発失格になるもの

- **`POST /initialize` が 30 秒以内にレスポンスを返さない。** 現在 27 MB の SQL を外部 `mysql` プロセスで流している（[章6](06-initialize.md)）ので、初期化を重くする変更（インデックス追加、派生テーブルの構築など）はここの所要時間を必ず計測する。
- **アプリケーション互換性チェックの失敗**（負荷走行の前に 10 秒以内で実行される）。
- **イス・物件の CSV 入稿（`POST /api/chair` / `POST /api/estate`）の失敗またはタイムアウト。** メッセージ末尾に `(critical error)` が付き、**1 回で失格**。この 2 本は N+1 で 1 行ずつ INSERT しているが（`go/main.go:384`, `:681`）、**触るときは最も慎重に**。
- **HTTP ステータスコードやレスポンス内容の誤りが 10 回以上**（1 回 50 点減点）。減点でスコアが 0 未満になっても失格。ステータスコードは**参考実装と同一のもの**が期待されている。たとえば `GET /api/recommended_estate/:id` は椅子が見つからないとき **400 を返す**（`go/main.go:830`。404 ではない）ので、直すと減点対象になりうる。
- **データが永続化されていない。** 追試でベンチ実施後に再起動され、直前の内容が保存されているか確認される。`innodb_flush_log_at_trx_commit` を緩める、DB をメモリ上に置く、といった変更はここに抵触する可能性がある。
- **ブラウザ上の表示が初期状態と変わっている。** ベンチは静的ファイルを叩かないが、追試でブラウザ表示を確認される。`/www/data` の静的資産や `location /` を壊してはいけない。
- **`isucon` 以外のアカウントの削除、既存公開鍵の削除。** 追試ができなくなるため失格。

### 減点・失格にならないもの（＝狙い目）

- **タイムアウト**は、CSV 入稿以外の API では失格にも減点にもならない（末尾に `（タイムアウトしました）` が付くだけ）。`docs/kickoff.md` に「素の状態では `POST /api/estate/nazotte` のタイムアウトが数件出るが正常」と記録されている。
- **bot への 503 が明示的に許可されている。** 以下の User-Agent 正規表現にマッチするリクエストには `503 Service Unavailable` を返してよく、減点されない。**現在アプリにも nginx にも bot 判定は一切実装されていない**（[章4](04-endpoints.md) / [章7](07-settings.md)）。

  ```
  /ISUCONbot(-Mobile)?/
  /ISUCONbot-Image\//
  /Mediapartners-ISUCON/
  /ISUCONCoffee/
  /ISUCONFeedSeeker(Beta)?/
  /crawler \(https:\/\/isucon\.invalid\/(support\/faq\/|help\/jp\/)/
  /isubot/
  /Isupider/
  /Isupider(-image)?\+/
  /(bot|crawler|spider)(?:[-_ .\/;@()]|$)/i
  ```

- **ベンチマーカーは API にしかリクエストしない。** 画像や HTML への負荷は掛からない。

### スコア計算

```
スコア = (イスの購入件数 + 物件の資料請求件数) - 減点
```

加点に直結するのは `POST /api/chair/buy/:id`（`go/main.go:533`）と `POST /api/estate/req_doc/:id`（`go/main.go:908`）の 2 本のみ（[章4](04-endpoints.md)）。

### 負荷走行の流れ

1. `POST /initialize`（30 秒以内）
2. アプリケーション互換性チェック（10 秒以内）
3. 負荷走行（60 秒）

各ステップで失敗するとその時点で停止する。

### 練習環境特有の注意

- 本戦はポータルからベンチを Enqueue するが、今回は i1 上で `cd isuumo/bench && ./bench -target-url http://127.0.0.1` を直接実行する（`docs/kickoff.md`）。
- 初期状態の実測スコアは **717**（2026-09-05、c8i.large 単体）。

---

[← 索引に戻る](README.md)
