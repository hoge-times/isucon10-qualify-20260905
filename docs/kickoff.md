# ISUCON10 予選 (isuumo) キックオフ大会プロファイル

作成日: 2026-09-05 / 環境: AWS 練習環境 (matsuu/aws-isucon `ami-03bbe60df80bdccc0`, c8i.large × 3)

## 対象ホスト

`HOSTS = i1 i2 i3` / **先頭ホスト = i1**（リポジトリの init・push・ベンチはここで行う）

| alias | public IP | private IP |
|---|---|---|
| i1（先頭） | 54.168.109.155 | 172.31.0.109 |
| i2 | 43.206.232.245 | 172.31.0.196 |
| i3 | 13.115.208.13 | 172.31.0.132 |

SSH ユーザーは `isucon`。`~/.ssh/isucon.conf`（`ForwardAgent yes`）から `ssh i1` で入れる。

## webapp ディレクトリ

- リポジトリルート: `/home/isucon/isuumo`
- webapp: `/home/isucon/isuumo/webapp`
- Go 実装: `/home/isucon/isuumo/webapp/go`（`main.go` / `go.mod` / ビルド成果物 `isuumo`）
- ベンチ: `/home/isucon/isuumo/bench`
- 言語別ディレクトリ: `go deno nodejs perl php python ruby rust`
- nginx 設定の配布元: `/home/isucon/isuumo/webapp/nginx`
- MySQL 設定・初期化 SQL: `/home/isucon/isuumo/webapp/mysql`

## 言語別のサービス名

すべて `/etc/systemd/system/` に配置。

| 言語 | サービス名 | 初期状態 |
|---|---|---|
| Go | `isuumo.go.service` | **enabled / active（初期実装）** |
| Ruby | `isuumo.ruby.service` | disabled |
| Perl | `isuumo.perl.service` | disabled |
| PHP | `isuumo.php.service` | disabled |
| Python | `isuumo.python.service` | disabled |
| Rust | `isuumo.rust.service` | disabled |
| Node.js | `isuumo.nodejs.service` | disabled |
| Deno | `isuumo.deno.service` | disabled（初期状態で互換性チェックに失敗する旨マニュアル記載） |

`isuumo.go.service` の要点:

```
WorkingDirectory=/home/isucon/isuumo/webapp/go
EnvironmentFile=/home/isucon/env.sh
ExecStart=/home/isucon/isuumo/webapp/go/isuumo
User=isucon / Group=isucon / Restart=always / Type=simple
```

## 言語切り替え手順（マニュアル記載）

```shell
sudo systemctl stop    isuumo.go.service
sudo systemctl disable isuumo.go.service
sudo systemctl start   isuumo.ruby.service
sudo systemctl enable  isuumo.ruby.service
```

PHP に切り替える場合のみ nginx 側も差し替える:

```shell
sudo unlink /etc/nginx/sites-enabled/isuumo.conf
sudo ln -s /etc/nginx/sites-available/isuumo.php.conf /etc/nginx/sites-enabled/isuumo.php.conf
sudo systemctl restart nginx
```

**今回は初期状態で Go が稼働しているため切り替え不要。**

## DB 接続情報

`/home/isucon/env.sh`（`EnvironmentFile` として読まれる）と Go 実装のデフォルト値が一致。

| 項目 | 値 |
|---|---|
| Host | `127.0.0.1` |
| Port | `3306` |
| User | `isucon` |
| Password | `isucon` |
| DBName | `isuumo` |

MySQL は `127.0.0.1:3306` のみで LISTEN（複数台構成にするときは bind-address と権限の変更が必要）。
DB を初期状態に戻す: `/home/isucon/isuumo/webapp/mysql/db/init.sh`

## 初期化エンドポイント

`POST /initialize`（`main.go:252` でルーティング、`initialize`（`main.go:287`）が実装）。
`webapp/mysql/db/` の `0_Schema.sql` → `1_DummyEstateData.sql` → `2_DummyChairData.sql` を順に流す。

- **30 秒以内**にレスポンスを返さないと失格。
- レスポンスは `{"language": "実装言語"}` の JSON。`language` が空だとベンチが失敗扱いにする。
- サーバー側でデータ構造を変えた場合、この処理が担保している整合性を漏れなく再現すること。

## ベンチ実行方法（練習環境）

先頭ホスト i1 上で実行する。

```shell
ssh i1 'cd isuumo/bench && ./bench -target-url http://127.0.0.1'
```

- 結果は末尾の JSON 行 `{"pass":true,"score":N,...}` から読む。
- 別サーバーを対象にするときは `-target-url http://<そのホストの private IP>` に差し替える。
- 素の状態では `POST /api/estate/nazotte` のタイムアウトが数件出るが正常。
- 初期状態の実測スコア: **717**（2026-09-05、c8i.large 単体、キックオフ前）。

## ポート構成

初期状態（3 台とも同じフルスタック）:

| 待受 | プロセス |
|---|---|
| `0.0.0.0:80` | nginx（リバースプロキシ） |
| `*:1323` | `isuumo`（アプリ本体） |
| `127.0.0.1:3306` | mysqld |

**2026-09-05 16:53 以降は役割を分けている**（詳細は [docs/report/server-split.md](report/server-split.md)）。

| ホスト | 役割 | 動いているもの |
|---|---|---|
| i1 | **web** | nginx (`0.0.0.0:80`) + `isuumo` (`*:1323`)。mysql は stop + disable |
| i2 | **MySQL 専有** | mysqld (`0.0.0.0:3306`)。nginx と `isuumo.go.service` は stop + disable |
| i3 | 不使用 | **別メンバーが使用中。デプロイも設定変更もしない** |

i1 の `/home/isucon/env.sh` は `MYSQL_HOST="172.31.0.196"`（i2 の private IP）を指す。
alp は i1、pt-query-digest は i2 から採る。

## ミドルウェア / OS

| 項目 | バージョン |
|---|---|
| OS | Ubuntu 18.04.5 LTS (Bionic) |
| nginx | 1.14.0 |
| MySQL | 5.7.33 |
| Go | 1.14.7 |

## 特記事項

### スコア計算

```
スコア = (イスの購入件数 + 物件の資料請求件数) - 減点
```

- 致命的なエラー（メッセージ末尾に `(critical error)`）は **1 回で失格**。イス・物件の CSV 入稿の失敗／タイムアウトが該当。
- HTTP ステータスコードやレスポンス内容の誤りは **1 回 50 点減点、10 回以上で失格**。
- 減点でスコアが 0 未満になると失格。
- タイムアウト（末尾 `（タイムアウトしました）`）は CSV 入稿以外では失格・減点にならない。

### 負荷走行の流れ

1. `POST /initialize`（30 秒以内）
2. アプリケーション互換性チェック（10 秒以内）
3. 負荷走行（60 秒）

各ステップで失敗するとその時点で停止。負荷走行中のタイムアウトや 503 の一部は無視されて継続する。

### 失格条件

- `POST /initialize` が 30 秒以内に返らない
- アプリケーション互換性チェックの失敗
- データが永続化されていない（ベンチ後の再起動で内容が失われる）
- ブラウザ上の表示が初期状態と変わっている
- `isucon` 以外のアカウントの削除や既存公開鍵の削除（追試不能で失格）

### bot への 503 が許可されている

以下の User-Agent 正規表現にマッチするリクエストには `503 Service Unavailable` を返してよく、減点されない（**スコア向上の狙い目**）。

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

### 本戦との差分（今回は練習なので該当なし）

- 本番はポータル（https://portal.isucon.net/contestant）からベンチを Enqueue する。今回は上記コマンドを i1 で直接実行する。
- 本番は踏み台経由の SSH。今回は各ホストに直接 SSH する。
- ベンチマーカーは API のみにリクエストする（静的ファイルへのリクエストは無し）が、追試でブラウザ表示を確認される。

## 配布資料

- `matsuu-isucon10-qualify-README.md` — https://github.com/matsuu/aws-isucon/tree/main/isucon10-qualify
- `isucon10_qualify_manual.md` — ISUCON10 予選マニュアル https://gist.github.com/progfay/25edb2a9ede4ca478cb3e2422f1f12f6
- レギュレーション（未取得）— http://isucon.net/archives/54753430.html。マニュアルと矛盾する場合はマニュアルが優先。

## 未確認

- レギュレーション本文（上記 URL）は未取得。
- `/etc/nginx/sites-enabled/isuumo.conf` の中身は未確認（段4の symlink 化で確認する）。
