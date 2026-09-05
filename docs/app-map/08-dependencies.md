## 8. 外部依存 / 複数台構成の障害

- **外部 API / モック**: **なし。** 外部通信を行うコードは無い(`http.Client` の生成も無し)
- **ファイル保存先**: なし。画像は `thumbnail varchar(128)` にパス文字列を持つだけで、バイナリは DB にもアプリにも無い
- **プロセスメモリに持っている状態**:
  - `chairSearchCondition` / `estateSearchCondition`(`go/main.go:28-29`)— `init()` で JSON から読む読み取り専用データ。**全台で同じ内容なので複数台化の障害にはならない**
  - それ以外のキャッシュ・カウンタ・セッションは**なし**
- **アプリ内での ID 採番**: なし。`id` は CSV / 初期データで与えられる
- **cron / タイマー**: `isucon` の crontab なし。`/etc/cron.d` は `mdadm` / `popularity-contest`(OS 由来)

**複数台構成の障害は実質的に `bind_address = 127.0.0.1` と `mysql.user` の `localhost` 限定のみ。** アプリ側は状態を持たないので水平展開しやすい。


---

[← 索引に戻る](README.md) ｜ [次: 触ってはいけない範囲 →](09-constraints.md)
