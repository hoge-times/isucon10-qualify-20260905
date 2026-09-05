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

    -- ORDER BY rent ASC, id ASC を filesort なしで返す(InnoDB は末尾に主キーが暗黙で付く)。
    -- rent >= ? AND rent < ? のレンジ絞り込みと COUNT(*) のカバリングも兼ねる。
    INDEX idx_rent (rent),
    -- なぞって検索の bounding box 用。緯度帯で 32,000 行 -> 約 491 行まで落ちる。
    INDEX idx_lat_lon (latitude, longitude),
    -- 人気順をインデックス順に読ませ、LIMIT で早期打ち切りする。
    INDEX idx_pop_desc (popularity_desc, id),
    -- GET /api/estate/search が件数表示のために毎回投げる COUNT(*) 用。
    -- COUNT には ORDER BY も LIMIT も無く早期打ち切りが効かないので、
    -- 検索に使う3列を全部入れて行本体を読まずに数え切れるようにする。
    INDEX idx_cover (rent, door_height, door_width),
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

    -- ORDER BY price ASC, id ASC を filesort なしで返す。
    -- stock > 0 は 32,000 行中 31,980 行が該当するので LIMIT 20 で即打ち切れる。
    -- price >= ? AND price < ? のレンジ絞り込みも兼ねる。
    INDEX idx_price (price),
    -- 人気順をインデックス順に読ませ、LIMIT で早期打ち切りする。
    INDEX idx_pop_desc (popularity_desc, id),
    -- GET /api/chair/search の COUNT(*) 用。estate と同じ理由。
    -- kind / color は VARCHAR(64) だが InnoDB では可変長で格納されるため、
    -- 実データ(kind 4種 / color 12種)なら索引サイズへの影響は小さい。
    INDEX idx_cover (price, height, width, depth, stock, kind, color),

    -- GET /api/chair/search の SELECT 用。等値条件を先頭に置いた絞り込み索引。
    --
    -- 検索は ORDER BY popularity_desc ASC, id ASC LIMIT ? OFFSET ? を持つ。
    -- オプティマイザは LIMIT があると idx_pop_desc を人気順に辿って早期打ち切り
    -- する計画を選びがちだが、その見積もりは「条件がすぐ埋まる」前提。条件が
    -- 厳しいと必要件数が集まらずテーブルをほぼ全部舐める(実測で 33,927 行読んで
    -- 25 行しか返さない)。
    --
    -- idx_cover では防げない。先頭が price のレンジなので絞り込みの見積もりが
    -- 甘く、オプティマイザは idx_pop_desc を選び続ける。先頭を等値の color / kind
    -- にすると見積もりが当たり、自分から絞り込み側へ乗り換える。
    --
    -- i2 実機での実測(price+height+kind+color、一致 25 件):
    --   追加前 26.16ms (idx_pop_desc, rows=141, filtered=0.04%)
    --   追加後  1.55ms (idx_color_price, rows=492, Using index condition)
    -- 条件が緩いとき(color のみ、一致 2,928 件)は追加後も idx_pop_desc のまま
    -- 0.28ms で、正しい判断が維持される。
    INDEX idx_color_price (color, price),
    INDEX idx_kind_price (kind, price)
);
