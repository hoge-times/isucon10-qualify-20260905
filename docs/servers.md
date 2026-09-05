# サーバー構成

**このファイルが現在のサーバー構成の唯一の正です。** 構成を変えたら、変えた人が同じ PR でここも更新してください(ワークスペースの `CLAUDE.md`「サーバー構成の記録(必須)」参照)。

最終更新: 2026-09-05 17:40 / iwashi623

## 現在の役割

<!-- ここは機械可読。report.sh などが読むので key=value の形を崩さないこと -->
```ini
bench=i1
app=i1
nginx=i1
db=i2
hosts=i1 i2 i3
```

| キー | 意味 |
|---|---|
| `bench` | ベンチマーカーを実行するサーバー |
| `app` | アプリ(webapp)が動いているサーバー |
| `nginx` | nginx が動いているサーバー(**alp の採取先**) |
| `db` | MySQL が動いているサーバー(**pt-query-digest の採取先**) |
| `hosts` | いま使っているサーバー全部(役割が無い台も含む) |

複数台にまたがる場合は空白区切りで並べます(例 `app=i1 i2`)。

## ホスト一覧

| alias | public IP | private IP | 現在の用途 |
|---|---|---|---|
| i1 | 54.168.109.155 | 172.31.0.109 | アプリ + nginx。ベンチもここで実行する。MySQL は停止済み |
| i2 | 43.206.232.245 | 172.31.0.196 | **MySQL 専有**。アプリと nginx は停止済み |
| i3 | 13.115.208.13 | 172.31.0.132 | 予備。アプリ / nginx / MySQL が単体で動いている。**別メンバーが検証に使っているので勝手に再起動しないこと** |

2026-09-05 17:40 時点の `systemctl is-active isuumo.go.service nginx mysql` の実測:

| host | isuumo.go | nginx | mysql |
|---|---|---|---|
| i1 | active | active | inactive |
| i2 | inactive | inactive | active |
| i3 | active | active | active |

## 注意

- **`Makefile` の `bench` / `pbnalp1` / `pbpt1` は `i1` 直値**です。web ホストを変えたらここも直してください。
- `make prepare` は web ホストで `make re`(アプリ + nginx)、DB ホストで `make dbre`(MySQL)を叩きます。**`make re` は MySQL を再起動しません**(i1 に MySQL がいないため)。スロークエリログを空にするのは `dbre` 側です。
- `upload2` / `upload3` は現構成では通常使いません。i2 はアプリを動かしておらず、i3 は別メンバーの作業台です。

## 変更履歴

| 日時 | 変更 | 実施者 |
|---|---|---|
| 2026-09-05 12:30 | キックオフ。全役割を i1 に置き、i2 / i3 は未使用 | iwashi623 |
| 2026-09-05 17:0x | MySQL を i2 に分離し、i1 を web 専有にする(PR #28) | (チーム) |
| 2026-09-05 17:40 | 現状を確認して本ファイルを新規作成。i3 は別メンバーが検証用に使用中 | iwashi623 |
