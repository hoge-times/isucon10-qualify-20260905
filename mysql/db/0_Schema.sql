DROP DATABASE IF EXISTS isuumo;
CREATE DATABASE isuumo;

DROP TABLE IF EXISTS isuumo.estate;
DROP TABLE IF EXISTS isuumo.chair;

CREATE TABLE isuumo.estate
(
    id          INTEGER             NOT NULL PRIMARY KEY,
    name        VARCHAR(64)         NOT NULL,
    description VARCHAR(4096)       NOT NULL,
    thumbnail   VARCHAR(128)        NOT NULL,
    address     VARCHAR(128)        NOT NULL,
    latitude    DOUBLE PRECISION    NOT NULL,
    longitude   DOUBLE PRECISION    NOT NULL,
    rent        INTEGER             NOT NULL,
    door_height INTEGER             NOT NULL,
    door_width  INTEGER             NOT NULL,
    features    VARCHAR(64)         NOT NULL,
    popularity  INTEGER             NOT NULL,
    -- MySQL 5.7 は降順インデックスを持てないため、popularity の符号を反転した
    -- 生成列を索引する。ORDER BY popularity_desc ASC, id ASC = 人気順。
    popularity_desc INTEGER AS (-popularity) STORED,

    -- latitude / longitude から自動生成する POINT。INSERT 側はカラム未指定のままでよい。
    -- 空間関数(ST_Contains 等)の引数座標順は coordinatesToText() の "緯度 経度" に合わせる。
    location    POINT GENERATED ALWAYS AS (POINT(latitude, longitude)) STORED NOT NULL,

    -- 検索バケット。GET /api/estate/search が受け取るのは rentRangeId のような
    -- バケット ID だけで、境界は fixture/estate_condition.json で固定されている。
    -- レンジ条件(rent >= ? AND rent < ?)を等値条件(rent_bucket = ?)に置き換えると、
    -- 複合インデックスの「定数に固定された等値プレフィックス」が伸び、その後ろの
    -- popularity_desc, id が ORDER BY をインデックス順で満たせるようになる。
    -- 結果として filesort が消え、LIMIT ? OFFSET ? で早期打ち切りできる。
    -- 境界値は go/main.go の validateBucketBoundaries() が起動時に fixture と突き合わせる。
    rent_bucket TINYINT AS (CASE WHEN rent < 50000 THEN 0 WHEN rent < 100000 THEN 1 WHEN rent < 150000 THEN 2 ELSE 3 END) STORED,
    dh_bucket   TINYINT AS (CASE WHEN door_height < 80 THEN 0 WHEN door_height < 110 THEN 1 WHEN door_height < 150 THEN 2 ELSE 3 END) STORED,
    dw_bucket   TINYINT AS (CASE WHEN door_width < 80 THEN 0 WHEN door_width < 110 THEN 1 WHEN door_width < 150 THEN 2 ELSE 3 END) STORED,

    -- ORDER BY rent ASC, id ASC を filesort なしで返す(GET /api/estate/low_priced)。
    -- InnoDB は末尾に主キーが暗黙で付くので (rent) は実質 (rent, id)。
    INDEX idx_rent (rent),
    -- なぞって検索の bounding box 用。緯度帯で 32,000 行 -> 約 491 行まで落ちる。
    INDEX idx_lat_lon (latitude, longitude),
    -- バケット条件が1つも付かない検索(features のみ等)と recommended_estate 用の人気順スキャン。
    INDEX idx_pop_desc (popularity_desc, id),
    -- 検索バケットの組み合わせ別インデックス。ベンチが投げる条件の組み合わせは
    -- rent / door_height / door_width の部分集合しか無く、下の4本で 94〜99% を
    -- 「等値プレフィックス + popularity_desc, id」に一致させられる。
    -- COUNT(*) も同じインデックスのレンジスキャン(Using index)で行本体を読まずに数え切れる。
    INDEX idx_b_r   (rent_bucket, popularity_desc, id),
    INDEX idx_b_rh  (rent_bucket, dh_bucket, popularity_desc, id),
    INDEX idx_b_rw  (rent_bucket, dw_bucket, popularity_desc, id),
    INDEX idx_b_rhw (rent_bucket, dh_bucket, dw_bucket, popularity_desc, id),
    -- なぞって検索の ST_Contains を1クエリで高速化する R-Tree 空間インデックス。
    SPATIAL INDEX idx_location (location)
);

CREATE TABLE isuumo.chair
(
    id          INTEGER         NOT NULL PRIMARY KEY,
    name        VARCHAR(64)     NOT NULL,
    description VARCHAR(4096)   NOT NULL,
    thumbnail   VARCHAR(128)    NOT NULL,
    price       INTEGER         NOT NULL,
    height      INTEGER         NOT NULL,
    width       INTEGER         NOT NULL,
    depth       INTEGER         NOT NULL,
    color       VARCHAR(64)     NOT NULL,
    features    VARCHAR(64)     NOT NULL,
    kind        VARCHAR(64)     NOT NULL,
    popularity  INTEGER         NOT NULL,
    stock       INTEGER         NOT NULL,
    -- estate と同じ理由の生成列。
    popularity_desc INTEGER AS (-popularity) STORED,

    -- 検索バケット(estate と同じ理由)。境界は fixture/chair_condition.json 固定で、
    -- price だけ 6 バケット、height / width / depth は 4 バケット。
    price_bucket  TINYINT AS (CASE WHEN price < 3000 THEN 0 WHEN price < 6000 THEN 1 WHEN price < 9000 THEN 2 WHEN price < 12000 THEN 3 WHEN price < 15000 THEN 4 ELSE 5 END) STORED,
    height_bucket TINYINT AS (CASE WHEN height < 80 THEN 0 WHEN height < 110 THEN 1 WHEN height < 150 THEN 2 ELSE 3 END) STORED,
    width_bucket  TINYINT AS (CASE WHEN width < 80 THEN 0 WHEN width < 110 THEN 1 WHEN width < 150 THEN 2 ELSE 3 END) STORED,
    depth_bucket  TINYINT AS (CASE WHEN depth < 80 THEN 0 WHEN depth < 110 THEN 1 WHEN depth < 150 THEN 2 ELSE 3 END) STORED,
    -- GET /api/chair/search は必ず stock > 0 を付ける。レンジ条件のままだと
    -- 等値プレフィックスがそこで途切れて ORDER BY を索引で解けないので等値にする。
    -- stock を更新するのは buyChair だけで、生成列なので自動で追随する。
    in_stock      TINYINT AS (stock > 0) STORED,

    -- ORDER BY price ASC, id ASC を filesort なしで返す(GET /api/chair/low_priced)。
    -- stock > 0 は 32,000 行中 31,980 行が該当するので LIMIT 20 で即打ち切れる。
    INDEX idx_price (price),
    -- バケット条件が1つも付かない検索(features のみ等)の人気順スキャン用。
    INDEX idx_pop_desc (popularity_desc, id),

    -- GET /api/chair/search の SELECT 用。等値条件を先頭に置いた絞り込み索引。
    --
    -- オプティマイザは LIMIT があると idx_pop_desc を人気順に辿って早期打ち切り
    -- する計画を選びがちだが、その見積もりは「条件がすぐ埋まる」前提。条件が
    -- 厳しいと必要件数が集まらずテーブルをほぼ全部舐める(実測で 33,927 行読んで
    -- 25 行しか返さない)。先頭を等値にした索引を置くと見積もりが当たり、
    -- オプティマイザが自分から絞り込み側へ乗り換える。
    --   i2 実機での実測(price+height+kind+color、一致 25 件):
    --     (color, price) 追加前 26.16ms (idx_pop_desc, rows=141, filtered=0.04%)
    --     (color, price) 追加後  1.55ms (idx_color_price, rows=492, Using index condition)
    --
    -- price をバケット等値にしたことで2列目も等値になり、その後ろに
    -- popularity_desc, id を置けるようになった。旧 (color, price) は price が
    -- レンジで等値プレフィックスがそこで切れていたため、絞り込みには効いても
    -- ORDER BY は filesort のままだった。この2本は両方を同時に解く。
    INDEX idx_b_color (color, price_bucket, popularity_desc, id),
    INDEX idx_b_kind  (kind, price_bucket, popularity_desc, id),
    -- kind / color が付かない検索用。chair は絞り込み列が6つあり組み合わせを
    -- 網羅できないので、出現率の高い price(約70%)だけを等値プレフィックスにして
    -- 人気順に読み、残りの条件は行で評価して LIMIT が埋まった時点で打ち切らせる。
    INDEX idx_b_sort (in_stock, price_bucket, popularity_desc, id),
    -- 検索の COUNT(*) 用。ORDER BY も LIMIT も無く早期打ち切りが効かないので、
    -- 検索に使う列を全部入れて行本体を読まずに数え切れるようにする。
    -- kind / color は VARCHAR(64) だが InnoDB では可変長で格納されるため、
    -- 実データ(kind 4種 / color 12種)なら索引サイズへの影響は小さい。
    INDEX idx_b_cover (in_stock, price_bucket, height_bucket, width_bucket, depth_bucket, kind, color)
);
