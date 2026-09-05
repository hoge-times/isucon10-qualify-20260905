# ログの停止 (nginx / MySQL / アプリ)

対象: `isucon10-qualify-20260905` / 2026-09-05
入力: [bench Issue #36](https://github.com/hoge-times/isucon10-qualify-20260905/issues/36)(ログ ON)

---

## 0. 要約

nginx のアクセスログ、MySQL のスロークエリログ、アプリのアクセスログを**既定で止めた**。**score 17204 → 22969 (+5765 / +33.5%)**。

計測にはログが要るので、**`make logon` / `make logoff` で切り替えられる形**にしてある。

## 1. なぜ止めたか

[db-split-by-table.md](db-split-by-table.md) の時点でボトルネックは web (i1) に移っていた。その i1 の CPU を見ると、**アプリでも nginx でもないプロセスが 14 ポイント近く食っていた**。

| プロセス | ログ ON | ログ OFF |
|---|---:|---:|
| `systemd-journal` | **7.32%** | **0.00%** |
| `rsyslogd` | **6.60%** | **0.00%** |

アプリが 1 リクエストにつき 1 行の JSON を stdout に吐き、それが journald に入り、さらに rsyslog に複製されていた。**スコアに一切寄与しない仕事**で、web が壁になっている状況では純粋な損。

## 2. 単純に消さなかった理由

ログを消すと `alp` と `pt-query-digest` が空になる。**しかもエラーにはならない。** `isucon-bench-report` は空のアクセスログでも Issue を作るので、「遅いクエリが1件も無い」中身の無い Issue が静かに残る。ワークスペースの `CLAUDE.md` が名指しで警告している事故そのもの。

そこで ON/OFF を切り替えられるようにし、**計測経路が自動で ON に戻る**ようにした。

| 用途 | コマンド | ログ |
|---|---|---|
| 計測(alp / pt を採る) | `make prepare` / `report.sh` | **自動で ON**(`nrestart` が `nlogon` を呼ぶ / `mrestart` が slow log を有効化) |
| 本番走行(スコア狙い) | `make logoff` → ベンチ | OFF |
| 手で戻す | `make logon` | ON |

**`make logoff` の後に `make prepare` を挟むとログが ON に戻る。** スコアを狙う走行では `logoff` → ベンチの順で叩くこと。

## 3. どう切り替えているか

### nginx

`nginx.conf` は http レベルで `access_log off;`。server ブロック(`sites-available/isuumo.conf`)が `include /etc/nginx/access-log.d/*.conf;` を持ち、`on.conf` があるときだけ **server レベルで http の `off` を上書き**する。

**`access_log off;` と同じレベルに後から `access_log path;` を足しても効かない**(nginx のドキュメントいわく「`off` はそのレベルの `access_log` を全部打ち消す」)。level を分けるのが要点。使い捨ての nginx を立てて次の3点を実機で確認済み。

- `access-log.d` が空 → 記録されない
- `on.conf` を置いて reload → ltsv で記録される
- `on.conf` を消して reload → 止まる
- ファイルが1つも無くても wildcard include はエラーにならない

**`access-log.d` は Git 管理外にしてある。** `/etc/nginx` はリポジトリへの symlink なので、実行時に追跡ファイルを書き換えるとサーバー側の作業ツリーが汚れて `git pull` が失敗する。

### アプリ

`middleware.Logger()` を `ISU_ACCESS_LOG` で切り替える。`env.sh` は Git 管理外なので `make alogon` / `alogoff` が直接書く。

**エラーログ (`c.Logger().Errorf`) は常に出す。** 正常系では1行も出ないのでコストがゼロで、これが無いと 500 が出たときに切り分けられない(DB 分割のときの `Table 'isuumo.chair' doesn't exist` はこのログで特定した)。`e.Debug` も `false` にした。

### MySQL

`set global slow_query_log` の切り替えだけ。設定ファイルは元から無効なので触っていない。

## 4. 結果

**score 17204 → 22969 (+5765 / +33.5%)** / pass

i1 の内訳(2 vCPU = 200%):

| プロセス | ログ ON | ログ OFF | 差 |
|---|---:|---:|---:|
| `systemd-journal` | 7.32% | **0.00%** | -7.32 |
| `rsyslogd` | 6.60% | **0.00%** | -6.60 |
| `isuumo` | 72.70% | **63.35%** | -9.35 |
| `nginx` | 14.85% | 16.10% | +1.25 |
| `bench` | 84.84% | 98.94% | +14.10 |

**`isuumo` 自身も 9.35 ポイント下がっている**(より多くのリクエストを捌きながら)。JSON の組み立てと書き込みがそのままアプリのコストだった。空いたぶんはベンチと nginx が使い、スループットになっている。

DB 側も素直に仕事が増えた。

| | ログ ON | ログ OFF |
|---|---:|---:|
| i2 `mysqld` | 58.6% | **158.2%** |
| i3 `mysqld` | (同走行) | **75.5%** |

## 5. 次にやること

i1 が 89.9% で依然として壁。`bench` が 98.94% を占めているので、**本戦(ベンチが外部)ではもっと余裕がある**点に注意。

1. **pprof でアプリの内訳を見る。** `isuumo` がまだ 63.35%。`make pprof` / `make getpprof`。
2. **ベンチを別の台に出して測り直す。** 練習環境は i1 でベンチが同居しており、web 側の数字が実態より悪く出る。i3 は `mysqld` 75.5% と空いているので、ここでベンチを回せば i1 の本当の余裕が分かる。
3. **DB は i2 (158.2%) に偏ったまま。** chair 側にまだ伸びしろがある。
