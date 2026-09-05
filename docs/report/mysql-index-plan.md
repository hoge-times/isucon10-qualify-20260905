# MySQL インデックス設計レポート（Slow クエリログ起点）

対象: `isucon10-qualify-20260905` / ホスト `i1` / 2026-09-05
入力: [bench Issue #2](https://github.com/hoge-times/isucon10-qualify-20260905/issues/2)（score=1096、pt-query-digest、alp）、[app-map](app-map/README.md)、[US 分析](../us/report.md)
検証: `i1` 上の MySQL 実機（`EXPLAIN`・行数カウント）、`~/isuumo/bench` のベンチ実装

---

## 0. 要約

- ベンチ走行 67 秒で MySQL の Exec time は **419 秒**（並列度 6.26x、`mysqld` の CPU は平均 157%／2 vCPU 上限 200%）。**Rows examined 359.80M**。
- `chair` / `estate` ともにセカンダリインデックスが **1 本も無い**（インデックス長 0 KB）。主要クエリは全部 `type=ALL` + `Using filesort`。
- Rows examined 359.8M ÷ 1 スキャン 29.8k 行 ≒ **約 12,000 回のフルスキャン / 67 秒**。内訳はベンチ実装から次のとおり再構成できる。

| 発生源 | 1 走行のクエリ数 | 全フルスキャンに占める割合 | 効く手 |
|---|---:|---:|---|
| `GET /api/estate/search`（COUNT + SELECT の 2 本） | 5,334 | 約 44% | **`estate(rent)`** |
| `GET /api/chair/search`（COUNT + SELECT の 2 本） | 4,260 | 約 35% | **`chair(price)`** ほか |
| `low_priced` chair / estate | 1,868 | 約 15% | **`chair(price)` / `estate(rent)`** |
| `GET /api/recommended_estate/:id` | 565 | 約 5% | 生成列（後述）＋条件簡約 |
| `POST /api/estate/nazotte`（bbox） | 283 | 約 2% | **`estate(latitude, longitude)`** |

- **MySQL 5.7.42 なので降順インデックスが無い。** 主要な検索が使う `ORDER BY popularity DESC, id ASC` は方向が混在しており、**どんなインデックスを貼っても filesort は消せない**。この系統は「WHERE で filesort の対象行を減らす」ことしかできない。
- 一方 `ORDER BY price ASC, id ASC` / `ORDER BY rent ASC, id ASC` は **インデックスだけで filesort が完全に消える**。ここが最も費用対効果が高い。
- **ベンチのロードフェーズは `features` を一度も投げない**（ベンチ実装のバグ、後述 §5）。`features LIKE '%...%'` 対策の優先度は低い。

---

## 1. 現状の EXPLAIN（インデックス追加前・実機で採取）

| クエリ | type | key | rows | Extra |
|---|---|---|---:|---|
| `chair WHERE stock>0 ORDER BY price ASC,id ASC LIMIT 20` | ALL | NULL | 29,246 | Using where; **Using filesort** |
| `estate ORDER BY rent ASC,id ASC LIMIT 20` | ALL | NULL | 29,271 | **Using filesort** |
| `estate WHERE rent>=100000 AND rent<150000 ORDER BY popularity DESC,id ASC LIMIT 25 OFFSET 25` | ALL | NULL | 29,271 | Using where; **Using filesort** |
| `chair WHERE price>=9000 AND price<12000 AND stock>0 ORDER BY popularity DESC,id ASC LIMIT 10` | ALL | NULL | 29,246 | Using where; **Using filesort** |
| `estate WHERE latitude<=… AND longitude<=… ORDER BY popularity DESC,id ASC` | ALL | NULL | 29,271 | Using where; **Using filesort** |
| `estate WHERE (door_width>=? AND door_height>=?) OR …×6 ORDER BY popularity DESC,id ASC LIMIT 20` | ALL | NULL | 29,271 | Using where; **Using filesort** |

全滅。`possible_keys` すら NULL。

---

## 2. データ分布（インデックス選定の根拠・実機で採取）

`chair` 32,000 行 / `estate` 32,000 行。

| 列 | distinct | 備考 |
|---|---:|---|
| `chair.price` | 15,434 | 検索は 6 バケット: 3,363 / 5,195 / 4,974 / 4,980 / 5,110 / 8,378 行 |
| `chair.stock` | 11 | **`stock > 0` は 32,000 行中 31,980 行（99.94%）が該当 → 絞り込みの役に立たない** |
| `chair.color` | 12 | 各 2,597〜2,756 行（約 8%）。**等値条件で最も選択性が高い** |
| `chair.kind` | 4 | 各 7,951〜8,019 行（25%） |
| `chair.height/width/depth` | 各 171 | 4 バケット: 9,466 / 5,655 / 7,427 / 9,452 行 |
| `chair.popularity` | 31,527 | ORDER BY 専用 |
| `estate.rent` | 29,186 | 4 バケット: 3,762 / 9,368 / 9,384 / 9,486 行 |
| `estate.door_width` | 171 | 4 バケット: 9,266 / 5,686 / 7,497 / 9,551 行 |
| `estate.door_height` | 171 | 4 バケット: 9,357 / 5,535 / 7,496 / 9,612 行 |
| `estate.latitude` | 32,000 | 32.19〜45.54。**なぞって検索の緯度帯は 491 行（1.5%）しか含まない** |
| `estate.longitude` | 32,000 | 129.02〜145.21。bbox 全体では 134 行（0.4%） |
| `estate.popularity` | 31,477 | ORDER BY 専用 |

---

## 3. 貼るべきインデックス

### 段 A: filesort が完全に消える 3 本（最優先）

```sql
ALTER TABLE isuumo.chair  ADD INDEX idx_price (price);
ALTER TABLE isuumo.estate ADD INDEX idx_rent  (rent);
ALTER TABLE isuumo.estate ADD INDEX idx_lat_lon (latitude, longitude);
```

**`chair(price)`** — digest rank 1（934 回 / 26.2 秒 / 6.3%、1 回 29.8k 行）
`SELECT * FROM chair WHERE stock > 0 ORDER BY price ASC, id ASC LIMIT 20`。
InnoDB のセカンダリインデックスは末尾に主キーが暗黙で付くので `(price)` は実質 `(price, id)`、`ORDER BY price ASC, id ASC` と完全一致する。`stock > 0` は 99.94% が該当するため、price 昇順に読んで 20〜21 件目で打ち切れる。**29.8k 行 → 約 20 行**。
加えて chair 検索の `price >= ? AND price < ?`（rank 8 ほか）の range にも効く。

**`estate(rent)`** — digest rank 3（934 回 / 22.1 秒 / 5.3%）＋ rank 4（532 回 / 17.0 秒）＋ rank 6（532 回 / 12.6 秒）
- `SELECT * FROM estate ORDER BY rent ASC, id ASC LIMIT 20` は WHERE すら無いので確実に **29.8k 行 → 20 行**。
- `WHERE rent >= ? AND rent < ?` は 3.8k〜9.5k 行に絞れる（**3.1〜7.8 倍削減**）。filesort は残るが対象行が減る。
- `SELECT COUNT(*) FROM estate WHERE rent >= ? AND rent < ?`（rank 6）は **カバリングインデックスのレンジスキャン**（`Using index`）になり、行本体を読まなくなる。
- ベンチが投げる estate 検索の **94%** に `rentRangeId` が含まれる（§5 の確率計算）。estate 検索 5,334 クエリのほぼ全部に効く。

**`estate(latitude, longitude)`** — digest rank 7（283 回 / 10.9 秒 / 2.6%）
`POST /api/estate/nazotte` の bounding box。実測で緯度帯だけで **32,000 行 → 491 行（65 倍削減）**、bbox 全体では 134 行。`latitude` のレンジスキャン後、`longitude` はインデックス内で評価できる（ICP）。**29.9k 行 → 約 491 行**。残る filesort は数百行なので無視できる。

> 段 A だけで digest 419 秒のうち **概算 60〜70 秒（15%前後）** を直接削り、フルスキャン約 12,000 回のうち 1,900 回を消滅、さらに 5,000 回以上を 1/3〜1/8 に縮める。

### 段 B: 検索の絞り込み用（段 A のベンチ結果を見てから）

ベンチが実際に投げる列だけに絞る。

```sql
-- estate: 検索条件は rent / door_height / door_width の3つだけ
ALTER TABLE isuumo.estate ADD INDEX idx_door_height (door_height);
ALTER TABLE isuumo.estate ADD INDEX idx_door_width  (door_width);

-- chair: 等値条件は kind / color の2つ。range と組み合わせる複合が効く
ALTER TABLE isuumo.chair ADD INDEX idx_color_price (color, price);
ALTER TABLE isuumo.chair ADD INDEX idx_kind_price  (kind, price);
ALTER TABLE isuumo.chair ADD INDEX idx_height (height);
ALTER TABLE isuumo.chair ADD INDEX idx_width  (width);
ALTER TABLE isuumo.chair ADD INDEX idx_depth  (depth);
```

判断の根拠と注意:

- **estate 側は単一列で十分**。`rent` / `door_height` / `door_width` は全部レンジ条件で、複合インデックスは先頭列より後ろをレンジに使えない。`(rent, door_height)` を作っても `(rent)` 以上の効果は出ない。
- **chair 側は `kind` / `color` が等値**なので、`(color, price)` `(kind, price)` の複合が効く。`color = ?`（2,600 行）→ `price` レンジ（1/6）で **約 430 行**まで落ちる。`price` 単体（約 5,000 行）や `color` 単体（2,600 行）より大幅に良い。
- MySQL 5.7 は複数レンジ条件で index merge intersection をほぼ選ばない。**テーブルごとに 1 本しか使われない**前提で、最も選択性の高いものが選ばれることを期待する設計にしている。
- 貼りすぎると optimizer の誤選択リスクが上がるので、**段 A → ベンチ → 段 B → ベンチ** の順で入れる。

### 貼ってはいけないもの

- **`chair(stock)`** — 99.94% が `stock > 0`。選択性ゼロで、optimizer に誤って選ばれると悪化する。
- **`chair(popularity)` / `estate(popularity)` 単体** — §4 のとおり 5.7 では ORDER BY に使えない。フィルタにも使われない。完全に無駄。
- **`features` 系** — §5 のとおりロードフェーズで発火しない。

---

## 4. インデックスでは解決しない問題

### 4-1. `ORDER BY popularity DESC, id ASC` は 5.7 では索引化できない

`SELECT VERSION()` = **5.7.42-0ubuntu0.18.04.1**。降順インデックス（`INDEX (popularity DESC, id ASC)`）は MySQL 8.0 以降の機能。5.7 では方向が混在する ORDER BY をインデックスで満たせず、必ず filesort になる。

これに該当するのは estate 検索 / chair 検索 / recommended_estate / nazotte の **ほぼ全て**。

対策（アプリ＋スキーマ変更を伴う）:

```sql
ALTER TABLE isuumo.estate
  ADD COLUMN popularity_desc INTEGER AS (-popularity) STORED,
  ADD INDEX idx_pop_desc (popularity_desc, id);
```

とし、アプリの `ORDER BY popularity DESC, id ASC` を `ORDER BY popularity_desc ASC, id ASC` に書き換える。これで **rank 2（`GET /api/recommended_estate/:id`、565 回 / 26.0 秒 / 6.2%）** が「popularity 順に読んで条件に合う 20 件で打ち切る」形になりうる。door 条件の通過率は 50% 程度なので、40 行ほど読んで終わる可能性がある。chair も同様。

ただし WHERE のレンジ条件と同時には使えない（optimizer はフィルタ用かソート用かどちらか一方にしかインデックスを使えない）ため、**段 A/B のフィルタ用インデックスとは併用ではなく競合する**。導入するなら効果測定必須。

### 4-2. `GET /api/recommended_estate/:id` の OR 6 項

```sql
WHERE (door_width >= w AND door_height >= h) OR (door_width >= w AND door_height >= d)
   OR (door_width >= h AND door_height >= w) OR (door_width >= h AND door_height >= d)
   OR (door_width >= d AND door_height >= w) OR (door_width >= d AND door_height >= h)
```

イスの 3 辺を昇順に `d1 <= d2 <= d3` と置くと、この 6 項の和集合は

```sql
WHERE (door_width >= d1 AND door_height >= d2) OR (door_width >= d2 AND door_height >= d1)
```

と**同値**（他の 4 項は上 2 項に包含される）。まずアプリ側で 2 項に簡約する。それでも `>=` の OR なのでインデックスのレンジ 1 本には落ちない。索引で殴るより 4-1 の生成列で ORDER BY を index scan にして LIMIT 20 で打ち切るほうが本命。

### 4-3. なぞって検索の N+1（digest rank 9）

`SELECT * FROM estate WHERE id = ? AND ST_Contains(...)` が **51,426 回 / 9.0 秒 / 2.2%**。1 回あたり 1 行しか見ておらず、インデックス（主キー）は既に効いている。**283 回の bbox 検索に対して平均 182 回のループ**という N+1 構造そのものが問題。`ST_Contains` を bbox クエリ側に畳み込んで 1 クエリにするのが正解で、インデックスの話ではない。

なお `estate` には `GEOMETRY` 列が無く（`latitude`/`longitude` が `DOUBLE` の別列）、SPATIAL INDEX は現状貼れない。段 A の `(latitude, longitude)` が現実的な代替。

### 4-4. ADMIN PREPARE が 81,480 回 / 14.0 秒（3.3%）

インデックスの問題ではない。DSN（`go/main.go:221`）に `?interpolateParams=true` を足すとサーバーサイド prepare が消え、この 14 秒がほぼ丸ごと消える。ついでに往復も減る。低リスク・高効果。

---

## 5. ベンチが実際に投げる検索条件（`~/isuumo/bench/scenario/searchQuery.go`）

インデックス選定の前提として、ベンチのクエリ生成を読んだ。

```go
// chair
r := rand.Intn(9)                      // → 0..8
if level >= 2 { r += rand.Intn(1) }    // rand.Intn(1) は常に 0
switch r {
case 0,1,2: priceRangeId
case 3,4:   heightRangeId
case 5:     widthRangeId
case 6:     depthRangeId
case 7:     kind
case 8:     color
case 9:     features   // ← 到達不能
}
```

`rand.Intn(1)` が常に 0 を返すため `r` は 0..8 のままで、**`case 9`（features）に到達しない**。estate 側も `rand.Intn(5)` → 0..4 で `case 5`（features）に到達しない。

つまり:

| テーブル | ロードフェーズで使われる検索列 | 1 パラメータあたりの出現確率 |
|---|---|---|
| `chair` | `price` 3/9, `height` 2/9, `width` 1/9, `depth` 1/9, `kind` 1/9, `color` 1/9 | — |
| `estate` | `rent` 3/5, `door_height` 1/5, `door_width` 1/5 | — |

パラメータ数は `level/2 + 1`。スコア 1096 は `BoundaryOfLevel = [300,600,800,900,1000,1100,…]` を 5 本超えているので **level 5 → 1 検索あたり 3 パラメータ**。3 回抽選での出現確率は:

- `estate.rent`: 1 − (2/5)³ = **94%**
- `estate.door_height` / `door_width`: 1 − (4/5)³ = **49%** ずつ
- `chair.price`: 1 − (6/9)³ = **70%**
- `chair.kind` / `color`: 1 − (8/9)³ = **30%** ずつ

`estate(rent)` と `chair(price)` を最優先にした根拠がこれ。

`features` はロードでは出ないが、**verify フェーズの snapshot（`~/isuumo/initial-data/result/verification_data/` に 200 件）には含まれる**ので、クエリを壊すと失格になる。`features LIKE` を消す最適化はしないこと。インデックスを足すだけなら影響しない。

---

## 6. 実装時の必須事項

**`POST /initialize` は `mysql/db/0_Schema.sql` を再投入して DB ごと作り直す**（`go/main.go:287`）。

```go
paths := []string{"0_Schema.sql", "1_DummyEstateData.sql", "2_DummyChairData.sql"}
// 0_Schema.sql は DROP DATABASE IF EXISTS isuumo; から始まる
```

したがって **手で `ALTER TABLE` を打ってもベンチの initialize で消える**。インデックスは必ず次のどちらかで永続化する。

1. `mysql/db/0_Schema.sql` の `CREATE TABLE` 内にインデックス定義を書く（簡単。ただし 32,000 行 × 2 の INSERT がインデックス更新を伴い initialize が遅くなる）
2. `1_DummyEstateData.sql` / `2_DummyChairData.sql` の末尾に `ALTER TABLE … ADD INDEX` を追記する（データ投入後に一括構築。こちらが速い）

現在の initialize は 1.56 秒（alp）、タイムアウトは 30 秒（`parameter.InitializeTimeout`）なので、どちらでも余裕はある。念のため initialize の所要時間を計測すること。

---

## 7. 推奨する進め方

| 段 | 内容 | 期待 |
|---|---|---|
| 1 | 段 A の 3 本を `mysql/db/*.sql` に入れてデプロイ → **ベンチ** | MySQL Exec time −15% 前後、rank 1/3/7 がほぼ消滅 |
| 2 | DSN に `interpolateParams=true` → **ベンチ** | ADMIN PREPARE 14 秒が消滅 |
| 3 | 段 B を追加 → **ベンチ**（悪化したら個別に外す） | chair/estate 検索の filesort 対象行を数倍削減 |
| 4 | `popularity_desc` 生成列 + アプリの ORDER BY 書き換え → **ベンチ** | rank 2（recommended_estate 26 秒）ほか |
| 5 | nazotte の N+1 を 1 クエリ化、recommended_estate の OR 6 項を 2 項に簡約 → **ベンチ** | rank 9（9 秒）＋ CPU |

各段でベンチを回して pass とスコアを確認する（`CLAUDE.md` のベンチ必須ルール）。

次回のベンチ計測では **pt-query-digest の全文**（`~/pt.log`）を確認すること。Issue #2 に貼られているのは先頭 300 行だけで、Exec time の **51.2%（214.7 秒）を占める MISC 499 items** の内訳が見えていない。

---

## 8. 段 A 適用後の実測（2026-09-05 06:39、ブランチ `perf/mysql-index-phase-a`）

`mysql/db/0_Schema.sql` の `CREATE TABLE` に `idx_price` / `idx_rent` / `idx_lat_lon` を追加し、`make re` 後にベンチを 1 回走行。

```
{"pass":true,"score":1294,"reason":"OK","language":"go"}
最終的な負荷レベル: 7
```

| 指標 | 段 A 前 | 段 A 後 | 差 |
|---|---:|---:|---|
| スコア | 1,096 | **1,294** | **+198（+18.1%）** |
| 最終負荷レベル | 5 | **7** | +2 |
| 総クエリ数 | 245.00k | 323.37k | +32.0% |
| **Rows examine 合計** | 359.80M | **259.02M** | **−28.0%** |
| **Rows examine / クエリ** | 1.50k | **839.90** | **−44.0%** |
| Exec time 合計 | 419 秒 | 419 秒 | ±0（2 vCPU が飽和したまま、こなす量が増えた） |
| `POST /initialize` | 1.560 秒 | 1.776 秒 | +0.216 秒（タイムアウト 30 秒に対し余裕） |

### EXPLAIN の変化（実機）

| クエリ | 前 | 後 |
|---|---|---|
| `chair WHERE stock>0 ORDER BY price ASC,id ASC LIMIT 20` | ALL / 29,246 行 / filesort | **index / `idx_price` / 20 行 / filesort なし** |
| `estate ORDER BY rent ASC,id ASC LIMIT 20` | ALL / 29,271 行 / filesort | **index / `idx_rent` / 20 行 / filesort なし** |
| `SELECT COUNT(*) FROM estate WHERE rent>=? AND rent<?` | ALL / 29,271 行 | **range / `idx_rent` / 9,654 行 / `Using index`（カバリング）** |
| `estate WHERE latitude<=? … longitude>=? ORDER BY popularity DESC,id ASC` | ALL / 29,271 行 | **range / `idx_lat_lon` / 506 行 / `Using index condition`** |
| `chair WHERE price>=? AND price<? AND stock>0 ORDER BY popularity DESC,id ASC LIMIT 10` | ALL / 29,246 行 | **range / `idx_price` / 5,153 行** |
| `estate WHERE rent>=? AND rent<? ORDER BY popularity DESC,id ASC LIMIT 25 OFFSET 25` | ALL / 29,271 行 | **ALL / 32,004 行（変わらず）** ← §8-1 |

### digest 上位からの消滅

| 段 A 前 | 段 A 後 |
|---|---|
| rank 1 `chair WHERE stock>0 ORDER BY price…`（934 回 / 26.2 秒） | **上位 20 から消滅** |
| rank 3 `estate ORDER BY rent…`（934 回 / 22.1 秒） | **上位 20 から消滅** |
| rank 7 nazotte の bbox（283 回 / 10.9 秒） | **上位 20 から消滅** |
| rank 6 `COUNT(*) … rent レンジ`（532 回 / 12.6 秒） | rank 14（671 回 / **4.13 秒**）＝ 呼び出し +26% で **−67%** |

alp でも `low_priced` 2 本が落ちている（リクエスト数は増えているのに合計時間が半減）。

| エンドポイント | 前 COUNT / SUM | 後 COUNT / SUM |
|---|---|---|
| `GET /api/chair/low_priced` | 934 / 36.45 秒 | 1,134 / **19.80 秒** |
| `GET /api/estate/low_priced` | 934 / 32.01 秒 | 1,134 / **18.50 秒** |

### 8-1. 効かなかったもの: `estate` 検索本体の `SELECT *`

`SELECT * FROM estate WHERE rent >= ? AND rent < ? ORDER BY popularity DESC, id ASC LIMIT 25 OFFSET 25` は `idx_rent` が `possible_keys` に出るのに **optimizer が選ばず ALL のまま**。フィルタ率 30%（9,654 行）だと「インデックスを辿って 9,654 行をランダムに行本体へ引きに行く」より「32,000 行を順に読む」ほうが安いと判断されている。5.7 の見積もりとして妥当で、`SELECT *` である以上カバリングにもできない。

digest でも per-call 0.0320 秒 → 0.0316 秒とほぼ変化なし（現在の rank 2、671 回 / 21.2 秒）。**これは §4-1 の `popularity_desc` 生成列（段 4）で ORDER BY 側を索引化するのが本筋**で、フィルタ用インデックスでは解けない。

### 8-2. 新しいボトルネック

| rank | クエリ | 回数 | 時間 | 対応する段 |
|---:|---|---:|---:|---|
| 1 | `recommended_estate` の OR 6 項 + `ORDER BY popularity DESC` | 638 | 31.1 秒 (7.4%) | 段 4（生成列）＋ §4-2（OR を 2 項に簡約） |
| 2 | `estate` 検索の `SELECT *`（§8-1） | 671 | 21.2 秒 (5.1%) | 段 4 |
| 3 | ADMIN PREPARE | 107,564 | 17.3 秒 (4.1%) | 段 2（`interpolateParams=true`） |
| 4 | nazotte の `ST_Contains` N+1 | 68,515 | 12.5 秒 (3.0%) | 段 5（1 クエリ化） |

`POST /api/estate/nazotte` は 346 リクエスト中 49 件が 2 秒のタイムアウトに当たっている（前回は 283 中 27 件）。bbox 自体は 506 行まで落ちたが、その後の **1 件ずつ `ST_Contains` を投げる N+1**（平均 198 回/リクエスト）が残っているため、負荷レベルが上がったぶん悪化した。段 5 の優先度が上がった。
