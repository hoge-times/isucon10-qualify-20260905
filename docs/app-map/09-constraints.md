## 9. 触ってはいけない範囲

マニュアルとレギュレーション(`docs/kickoff.md` の特記事項)より。

- **`POST /initialize` が 30 秒以内に返らないと失格**
- **アプリケーション互換性チェック(10秒以内)の失敗で失格**
- **データが永続化されていない**(ベンチ後の再起動で内容が失われる)と失格 — `innodb_flush_log_at_trx_commit` を触るときの制約
- **ブラウザ上の表示が初期状態と変わっている**と失格 — 静的ファイル配信(`location / { root /www/data; }`)を壊さないこと
- **`isucon` 以外のアカウント削除や既存公開鍵の削除**は追試不能で失格
- **CSV 入稿(`POST /api/chair` / `POST /api/estate`)の失敗・タイムアウトは `(critical error)` で一発失格**
- HTTP ステータスコードやレスポンス内容の誤りは 1 回 50 点減点、**10 回以上で失格**
- スコア = イスの購入件数 + 物件の資料請求件数 − 減点。**加点は `POST /api/chair/buy/:id` と `POST /api/estate/req_doc/:id` の2本のみ**


---

[← 索引に戻る](README.md)
