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

    -- ORDER BY rent ASC, id ASC を filesort なしで返す(InnoDB は末尾に主キーが暗黙で付く)。
    -- rent >= ? AND rent < ? のレンジ絞り込みと COUNT(*) のカバリングも兼ねる。
    INDEX idx_rent (rent),
    -- なぞって検索の bounding box 用。緯度帯で 32,000 行 -> 約 491 行まで落ちる。
    INDEX idx_lat_lon (latitude, longitude)
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

    -- ORDER BY price ASC, id ASC を filesort なしで返す。
    -- stock > 0 は 32,000 行中 31,980 行が該当するので LIMIT 20 で即打ち切れる。
    -- price >= ? AND price < ? のレンジ絞り込みも兼ねる。
    INDEX idx_price (price)
);
