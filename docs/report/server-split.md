# サーバー分割 (i1 = web / i2 = MySQL 専有)

対象: `isucon10-qualify-20260905` / 2026-09-05
入力: [bench Issue #22](https://github.com/hoge-times/isucon10-qualify-20260905/issues/22)(分離前)、[bench Issue #26](https://github.com/hoge-times/isucon10-qualify-20260905/issues/26)(分離後)

---

## 0. 要約

3 台とも独立したフルスタックとして動かしていたのを、**i1 = web (nginx + アプリ) / i2 = MySQL 専有** に分けた。**score 2203 → 4780 (+2577 / 2.17 倍)**。

**i3 は別メンバーが使用中なので触っていない。** Makefile の一括デプロイ対象からも外してある。

## 1. なぜ分けたか

分離前 (Issue #22、i1 単体、2 vCPU = 200%) の内訳:

| プロセス | 平均 %CPU |
|---|---:|
| `mysqld` | 132.7% |
| `bench` | 24.1% |
| `isuumo` | 23.0% |
| `nginx` | 5.9% |
| `systemd-journal` | 2.9% |
| **合計** | **188.6% / 200%** |

CPU が完全に飽和していた。決定打は **`GET /api/chair/:id` が avg 23ms / P90 72ms かかっていたこと**で、この経路は PR #20 でプロセス内キャッシュ済みなので DB を引いていない。つまり DB の遅さではなく **CPU の待ち行列**が効いていた。MySQL が欲しがっている CPU をアプリとベンチが奪い合っている状態。

## 2. 実際にやったこと

### i2 (MySQL 専有にする)

1. `mysql/mysql.conf.d/mysqld.cnf` の `bind-address` を `127.0.0.1` → `0.0.0.0`。
   `/etc/mysql` はリポジトリの `webapp/mysql` への symlink (キックオフ段4) なので、**`git pull` + `systemctl restart mysql` で反映される**。
2. リモート接続用のユーザーを作る。**`0_Schema.sql` の `DROP DATABASE` では権限は消えない**ので一度きりでよい。
   ```sql
   CREATE USER IF NOT EXISTS 'isucon'@'%' IDENTIFIED BY 'isucon';
   GRANT ALL PRIVILEGES ON *.* TO 'isucon'@'%' WITH GRANT OPTION;
   FLUSH PRIVILEGES;
   ```
3. `isuumo.go.service` と `nginx` を stop + disable。

### i1 (web 専有にする)

1. `/home/isucon/env.sh` の `MYSQL_HOST` を `127.0.0.1` → `172.31.0.196` (i2 の private IP)。
   このファイルは `isuumo.go.service` の `EnvironmentFile` なので、アプリ再起動で効く。**リポジトリ管理外**なので新しいサーバーでは手で書く必要がある。
2. `mysql` を stop + disable。
3. アプリを再起動。

### 確認したこと

- AWS の Security Group は VPC 内の 3306 を通していたので**変更不要**だった。
- `POST /initialize` はアプリが `mysql -h $MYSQL_HOST ... < *.sql` を exec する実装 (`go/main.go` の `initialize`)。27MB の SQL をネットワーク越しに流すことになるが、**2.076s → 2.29s** で 30 秒制限に対して十分余裕がある。
- `latitude`/`longitude` の生成列 `location` を使う nazotte (PR #16) と併用して全エンドポイント 200。

## 3. 結果 (Issue #26)

| | i1 (web) | i2 (db) |
|---|---:|---:|
| CPU 平均 | **32.3%** | **81.2%** |
| CPU 最大 | 45.7% | 100.0% |
| 主プロセス | `isuumo` 21.4% / `nginx` 7.0% / `bench` 26.7% | `mysqld` **160.0%** |

`mysqld` が **132.7% → 160.0%** まで伸びた。頭打ちだったぶんが素直にスループットになっている。

スループットの伸び (Issue #22 → #26):

| エンドポイント | 前 | 後 |
|---|---:|---:|
| `POST /api/estate/nazotte` | 413 | 2851 |
| `POST /api/estate/req_doc/:id` | 1646 | 4032 |
| `POST /api/chair/buy/:id` | 557 | 750 |
| `GET /api/estate/search` | 6599 | 7865 |

スコアは購入数 + 資料請求数なので、`buy` と `req_doc` の伸びがそのまま効いている。

## 4. 運用の変更

`Makefile` の再起動ターゲットを役割ごとに分けた。

| ターゲット | 実行場所 | 内容 |
|---|---|---|
| `make re` | web ホスト (i1) | アプリ + nginx の再起動、アクセスログ初期化 |
| `make dbre` | DB ホスト (i2) | MySQL 再起動、スロークエリログ初期化 |
| `make prepare` | ローカル | 上の 2 つを ssh 越しにまとめて叩く。**ベンチ前はこれ** |
| `make all` | ローカル | アプリが動くのは web ホストだけなので `upload1` のみ |

ログの採取先も分かれた。**alp は i1、pt-query-digest は i2**。

```
make pbnalp1     # alp   (i1 の nginx アクセスログ)
make pbpt2       # pt    (i2 の MySQL スロークエリログ)
```

> **`isucon-bench-report` スキルは複数台構成に未対応。** `--host` 1 つで「ベンチ実行先 + nginx ログ + スロークエリログ + top」を全部まかなう作りなので、分離後は `--host i1` にすると pt-query-digest が取れず、`--host i2` にするとベンチと alp が取れない。Issue #26 は手で採取して作った。スキル側に `--db-host` を足す改修が必要。

## 5. 次にやること

ボトルネックは **i2 の MySQL (mysqld 160% / ホスト CPU 最大 100%)** のまま。web 側は 32.3% と大きく空いている。

1. **nginx で bot に 503 を返す。** 全リクエストの 53.7% が許可リストの UA にマッチし、reqtime の 33% (630 秒) を占める。うち bot の `chair/search` + `estate/search` が 334 秒あり、いま一番重い MySQL の仕事そのもの。
2. **検索クエリのバケット化。** `chair` / `estate` の検索は 1 回あたり 8k〜34k 行を読んでいる ([mysql-index-plan.md](mysql-index-plan.md) の段 B の先)。バケット ID の生成列 + `(bucket…, popularity_desc, id)` の複合インデックスで filesort と OFFSET スキャンを消す。
3. **`db.SetMaxOpenConns(10)` の見直し。** i2 の CPU 平均が 81.2% で振り切っていないので、接続数が上限になっている可能性がある。
