/* ===================================================================
   AIRBNB NEW YORK vs LONDON - COMPLETE MySQL SCRIPT (scripts 00-06 combined)
   Run in MySQL Workbench (Execute all) or:
       mysql --local-infile=1 -u root -p < Airbnb_NYC_London_FULL.sql
   Before running:  SET GLOBAL local_infile = 1;   and in Workbench add
   OPT_LOCAL_INFILE=1 under Connection > Advanced > Others.
   Raise Edit > Preferences > SQL Editor > DBMS read timeout to 3600.
   =================================================================== */


/* =====================================================================
   AIRBNB NEW YORK vs LONDON  -  MySQL ANALYTICS WAREHOUSE
   Script 00 : Database, parameters and audit tables
   ---------------------------------------------------------------------
   Target     : MySQL 8.0+  (tested end-to-end on the full dataset)
   Run order  : 00 -> 01 -> 02 -> 03 -> 04 -> 05 -> 06
   Data source: Inside Airbnb snapshots  (NYC 2026-09-14, London 2026-09-17)
   ===================================================================== */

DROP DATABASE IF EXISTS airbnb_analytics;
CREATE DATABASE airbnb_analytics
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;
USE airbnb_analytics;

/* ---------------------------------------------------------------------
   1. PARAMETER TABLE  - every business assumption lives here, not in code.
      Change a value and re-run scripts 02-03 (or CALL sp_refresh_all()).
   --------------------------------------------------------------------- */
CREATE TABLE etl_parameter (
    param_name   VARCHAR(50)   PRIMARY KEY,
    param_value  DECIMAL(12,4) NOT NULL,
    description  VARCHAR(255)
);

INSERT INTO etl_parameter VALUES
 ('fx_gbp_to_usd',        1.3371, 'GBP/USD mid-rate on 17-Sep-2026 (London snapshot date)'),
 ('fx_usd_to_usd',        1.0000, 'Base currency'),
 ('review_rate',          0.5000, 'Share of stays that leave a review (Inside Airbnb "San Francisco model")'),
 ('default_stay_nights',  3.0000, 'Assumed average stay when minimum_nights is lower'),
 ('max_occupancy',        0.7000, 'Cap on estimated occupancy (70% of 365 nights)'),
 ('price_floor_usd',     10.0000, 'Nightly prices below this are treated as data errors'),
 ('price_outlier_pctl',   0.9900, 'Prices above this percentile (per city) are flagged as outliers'),
 ('long_stay_nights',    30.0000, 'Minimum-night threshold for "long-term rental" (NYC Local Law 18)');

/* ---------------------------------------------------------------------
   2. CITY REFERENCE TABLE
   --------------------------------------------------------------------- */
CREATE TABLE dim_city (
    city_code        CHAR(3)      PRIMARY KEY,
    city_name        VARCHAR(30)  NOT NULL,
    country          VARCHAR(30)  NOT NULL,
    local_currency   CHAR(3)      NOT NULL,
    fx_to_usd        DECIMAL(10,4) NOT NULL,
    snapshot_date    DATE         NOT NULL,   -- day the Inside Airbnb scrape started
    scrape_end_date  DATE         NOT NULL,   -- last date present in the scraped data
    regulation_note  VARCHAR(255)
);

INSERT INTO dim_city VALUES
 ('NYC','New York','United States','USD',
   (SELECT param_value FROM etl_parameter WHERE param_name='fx_usd_to_usd'),
   '2026-09-14','2026-09-14','Local Law 18 (enforced Sep-2023): stays < 30 nights need host registration'),
 ('LON','London','United Kingdom','GBP',
   (SELECT param_value FROM etl_parameter WHERE param_name='fx_gbp_to_usd'),
   '2026-09-17','2026-09-22','Entire-home short lets capped at 90 nights per calendar year without planning permission');

/* ---------------------------------------------------------------------
   3. AUDIT TABLES - ETL run log and data-quality log
   --------------------------------------------------------------------- */
CREATE TABLE etl_run_log (
    run_id       INT AUTO_INCREMENT PRIMARY KEY,
    step_name    VARCHAR(80)  NOT NULL,
    row_count    BIGINT,
    started_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    note         VARCHAR(255)
);

CREATE TABLE data_quality_log (
    dq_id          INT AUTO_INCREMENT PRIMARY KEY,
    city_code      CHAR(3),
    table_name     VARCHAR(40),
    rule_name      VARCHAR(80),
    action_taken   VARCHAR(120),
    rows_affected  BIGINT,
    logged_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO etl_run_log (step_name, note) VALUES ('00_setup', 'Database, parameters and audit tables created');


/* =====================================================================
   Script 01 : EXTRACT + LOAD  ->  raw staging tables  (the "EL" of ELT)
   ---------------------------------------------------------------------
   BEFORE RUNNING
   1. Enable LOCAL INFILE (once, as root):
          SET GLOBAL local_infile = 1;
      In MySQL Workbench: Edit Connection > Advanced > Others:  OPT_LOCAL_INFILE=1
      (or start the CLI as:  mysql --local-infile=1 -u root -p)
   2. File paths below point to:
          data/
      These are relative to the folder you start mysql from (run it from the
      repository root). In Workbench, Find & Replace data/ with an absolute
      path to the data folder (keep forward slashes).

   DESIGN NOTE
   Staging tables keep every column as text, exactly as delivered. Nothing
   is rejected at load time; all typing and cleaning happens in SQL (script 02),
   so every cleaning decision is visible and auditable. This mirrors how
   Airbnb lands raw data in HDFS/Hive before transforming it.
   The calendar (~44.5 M rows) is the exception: it is typed during load
   because copying it twice would double load time.
   ===================================================================== */

USE airbnb_analytics;

/* ---------- 1. STAGING TABLES --------------------------------------- */
DROP TABLE IF EXISTS stg_listings;
CREATE TABLE stg_listings (
    city_code                       CHAR(3),
    id                              VARCHAR(30),
    name                            VARCHAR(600),
    host_id                         VARCHAR(30),
    host_profile_id                 VARCHAR(40),
    host_name                       VARCHAR(255),
    neighbourhood_group             VARCHAR(100),
    neighbourhood                   VARCHAR(100),
    latitude                        VARCHAR(30),
    longitude                       VARCHAR(30),
    room_type                       VARCHAR(50),
    price                           VARCHAR(30),
    minimum_nights                  VARCHAR(20),
    number_of_reviews               VARCHAR(20),
    last_review                     VARCHAR(20),
    reviews_per_month               VARCHAR(20),
    calculated_host_listings_count  VARCHAR(20),
    availability_365                VARCHAR(20),
    number_of_reviews_ltm           VARCHAR(20),
    license                         VARCHAR(255),
    loaded_at                       DATETIME
) ENGINE=InnoDB;

DROP TABLE IF EXISTS stg_reviews;
CREATE TABLE stg_reviews (
    city_code    CHAR(3),
    listing_id   VARCHAR(30),
    review_date  VARCHAR(20)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS stg_neighbourhoods;
CREATE TABLE stg_neighbourhoods (
    city_code            CHAR(3),
    neighbourhood_group  VARCHAR(100),
    neighbourhood        VARCHAR(100)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS stg_calendar;
CREATE TABLE stg_calendar (
    city_code       CHAR(3)  NOT NULL,
    listing_id      BIGINT   NOT NULL,
    cal_date        DATE     NOT NULL,
    is_available    TINYINT  NOT NULL,     -- 1 = open for booking, 0 = booked OR blocked by host
    minimum_nights  INT,
    maximum_nights  INT
) ENGINE=InnoDB;

/* ---------- 2. LOAD: LISTINGS --------------------------------------- */
-- ESCAPED BY '' : listing names contain back-slashes; quotes are doubled ("") per CSV standard
-- Multi-line listing names are handled by OPTIONALLY ENCLOSED BY '"'
LOAD DATA LOCAL INFILE 'data/nyc_listings.csv'
INTO TABLE stg_listings CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(id, name, host_id, host_profile_id, host_name, neighbourhood_group, neighbourhood,
 latitude, longitude, room_type, price, minimum_nights, number_of_reviews, last_review,
 reviews_per_month, calculated_host_listings_count, availability_365, number_of_reviews_ltm, license)
SET city_code = 'NYC', loaded_at = NOW();

LOAD DATA LOCAL INFILE 'data/london_listings.csv'
INTO TABLE stg_listings CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(id, name, host_id, host_profile_id, host_name, neighbourhood_group, neighbourhood,
 latitude, longitude, room_type, price, minimum_nights, number_of_reviews, last_review,
 reviews_per_month, calculated_host_listings_count, availability_365, number_of_reviews_ltm, license)
SET city_code = 'LON', loaded_at = NOW();

/* ---------- 3. LOAD: REVIEWS ---------------------------------------- */
LOAD DATA LOCAL INFILE 'data/nyc_reviews.csv'
INTO TABLE stg_reviews
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES
(listing_id, review_date) SET city_code = 'NYC';

LOAD DATA LOCAL INFILE 'data/london_reviews.csv'
INTO TABLE stg_reviews
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES
(listing_id, review_date) SET city_code = 'LON';

/* ---------- 4. LOAD: NEIGHBOURHOODS --------------------------------- */
LOAD DATA LOCAL INFILE 'data/nyc_neighbourhoods.csv'
INTO TABLE stg_neighbourhoods CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES
(neighbourhood_group, neighbourhood) SET city_code = 'NYC';

LOAD DATA LOCAL INFILE 'data/london_neighbourhoods.csv'
INTO TABLE stg_neighbourhoods CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES
(neighbourhood_group, neighbourhood) SET city_code = 'LON';

/* ---------- 5. LOAD: CALENDAR (≈10.9 M NYC + 33.6 M London rows) ----
   Expect roughly 3-10 minutes depending on your laptop.               */
LOAD DATA LOCAL INFILE 'data/nyc_calendar.csv'
INTO TABLE stg_calendar
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES
(listing_id, @cal_date, @available, @min_n, @max_n)
SET city_code      = 'NYC',
    cal_date       = STR_TO_DATE(@cal_date, '%Y-%m-%d'),
    is_available   = IF(@available = 't', 1, 0),
    minimum_nights = NULLIF(@min_n, ''),
    maximum_nights = NULLIF(@max_n, '');

LOAD DATA LOCAL INFILE 'data/london_calendar.csv'
INTO TABLE stg_calendar
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES
(listing_id, @cal_date, @available, @min_n, @max_n)
SET city_code      = 'LON',
    cal_date       = STR_TO_DATE(@cal_date, '%Y-%m-%d'),
    is_available   = IF(@available = 't', 1, 0),
    minimum_nights = NULLIF(@min_n, ''),
    maximum_nights = NULLIF(@max_n, '');

CREATE INDEX ix_stg_cal_listing ON stg_calendar (listing_id);

/* ---------- 6. LOAD AUDIT ------------------------------------------- */
INSERT INTO etl_run_log (step_name, row_count, note)
SELECT CONCAT('01_load stg_listings ', city_code), COUNT(*), 'raw rows loaded' FROM stg_listings GROUP BY city_code
UNION ALL
SELECT CONCAT('01_load stg_reviews ', city_code), COUNT(*), 'raw rows loaded' FROM stg_reviews GROUP BY city_code
UNION ALL
SELECT CONCAT('01_load stg_calendar ', city_code), COUNT(*), 'raw rows loaded' FROM stg_calendar GROUP BY city_code
UNION ALL
SELECT CONCAT('01_load stg_neighbourhoods ', city_code), COUNT(*), 'raw rows loaded' FROM stg_neighbourhoods GROUP BY city_code;

-- Expected: listings NYC 29,918 | LON 91,954 ; reviews NYC 999,099 | LON 2,323,969
--           calendar NYC 10,920,077 | LON 33,563,890 ; neighbourhoods NYC 230 | LON 33
SELECT step_name, FORMAT(row_count,0) AS row_count FROM etl_run_log WHERE step_name LIKE '01_load%';


/* =====================================================================
   Script 02 : TRANSFORM + CLEAN  ->  star schema  (the "T" of ELT)
   ---------------------------------------------------------------------
   Output tables
     dim_neighbourhood   one row per neighbourhood (NYC) / borough (London)
     dim_room_type       4 room types
     dim_host            one row per host (hosts can operate in both cities)
     fact_listing        one row per listing - cleaned, typed, enriched
     fact_review         one row per review (date-level demand signal)
     fact_calendar       one row per listing per day, next 365 days
   Every cleaning rule writes how many rows it touched to data_quality_log.
   ===================================================================== */

USE airbnb_analytics;

-- Read business parameters into session variables
SET @fx_gbp        = (SELECT param_value FROM etl_parameter WHERE param_name = 'fx_gbp_to_usd');
SET @review_rate   = (SELECT param_value FROM etl_parameter WHERE param_name = 'review_rate');
SET @default_stay  = (SELECT param_value FROM etl_parameter WHERE param_name = 'default_stay_nights');
SET @max_occ       = (SELECT param_value FROM etl_parameter WHERE param_name = 'max_occupancy');
SET @price_floor   = (SELECT param_value FROM etl_parameter WHERE param_name = 'price_floor_usd');
SET @outlier_pctl  = (SELECT param_value FROM etl_parameter WHERE param_name = 'price_outlier_pctl');
SET @long_stay     = (SELECT param_value FROM etl_parameter WHERE param_name = 'long_stay_nights');

TRUNCATE TABLE data_quality_log;

/* =====================================================================
   STEP 1 - TYPE AND STANDARDISE LISTINGS  (tmp_listing_typed)
   ===================================================================== */
DROP TABLE IF EXISTS tmp_listing_typed;
CREATE TABLE tmp_listing_typed AS
SELECT
    s.city_code,
    CAST(TRIM(s.id) AS UNSIGNED)                                   AS listing_id,
    -- collapse line-breaks / repeated spaces inside listing names
    TRIM(REGEXP_REPLACE(s.name, '[[:space:]]+', ' '))              AS listing_name,
    CAST(TRIM(s.host_id) AS UNSIGNED)                              AS host_id,
    COALESCE(NULLIF(TRIM(s.host_name), ''), 'Unknown host')        AS host_name,
    -- London has a single geographic level: the borough sits in "neighbourhood"
    CASE WHEN s.city_code = 'NYC' THEN TRIM(s.neighbourhood_group)
         ELSE TRIM(s.neighbourhood) END                            AS borough,
    TRIM(s.neighbourhood)                                          AS neighbourhood,
    CAST(NULLIF(TRIM(s.latitude),  '') AS DECIMAL(9,6))            AS latitude,
    CAST(NULLIF(TRIM(s.longitude), '') AS DECIMAL(9,6))            AS longitude,
    TRIM(s.room_type)                                              AS room_type,
    -- strip currency symbols / thousands separators before casting
    CAST(NULLIF(REPLACE(REPLACE(REPLACE(TRIM(s.price), '$', ''), '£', ''), ',', ''), '')
         AS DECIMAL(12,2))                                         AS price_local,
    CAST(NULLIF(TRIM(s.minimum_nights), '') AS DECIMAL(10,0))      AS minimum_nights_raw,
    CAST(NULLIF(TRIM(s.number_of_reviews), '') AS UNSIGNED)        AS number_of_reviews,
    STR_TO_DATE(NULLIF(TRIM(s.last_review), ''), '%Y-%m-%d')       AS last_review_date,
    CAST(NULLIF(TRIM(s.reviews_per_month), '') AS DECIMAL(8,2))    AS reviews_per_month_raw,
    CAST(NULLIF(TRIM(s.calculated_host_listings_count), '') AS UNSIGNED) AS host_listings_in_city,
    CAST(NULLIF(TRIM(s.availability_365), '') AS UNSIGNED)         AS availability_365,
    CAST(NULLIF(TRIM(s.number_of_reviews_ltm), '') AS UNSIGNED)    AS reviews_ltm,
    NULLIF(TRIM(s.license), '')                                    AS license_raw
FROM stg_listings s
WHERE NULLIF(TRIM(s.id), '') IS NOT NULL;

ALTER TABLE tmp_listing_typed ADD INDEX ix_tlt (city_code, listing_id);

/* ---------- Data-quality profiling (logged before fixes) ------------- */
INSERT INTO data_quality_log (city_code, table_name, rule_name, action_taken, rows_affected)
SELECT city_code, 'listings', 'R1 Missing price',
       'Kept; price_status = Missing; excluded from price & revenue KPIs',
       SUM(price_local IS NULL) FROM tmp_listing_typed GROUP BY city_code
UNION ALL
SELECT city_code, 'listings', 'R4 Missing minimum_nights',
       'Imputed with city median minimum_nights', SUM(minimum_nights_raw IS NULL)
FROM tmp_listing_typed GROUP BY city_code
UNION ALL
SELECT city_code, 'listings', 'R5 minimum_nights > 365',
       'Capped at 365', SUM(minimum_nights_raw > 365) FROM tmp_listing_typed GROUP BY city_code
UNION ALL
SELECT city_code, 'listings', 'R6 reviews_per_month NULL (never reviewed)',
       'Set to 0', SUM(reviews_per_month_raw IS NULL) FROM tmp_listing_typed GROUP BY city_code
UNION ALL
SELECT city_code, 'listings', 'R7 Coordinates outside city bounding box',
       'Flagged (geo_valid = 0)',
       SUM(CASE WHEN city_code = 'NYC'
                 THEN NOT (latitude BETWEEN 40.40 AND 41.00 AND longitude BETWEEN -74.30 AND -73.60)
                 ELSE NOT (latitude BETWEEN 51.25 AND 51.75 AND longitude BETWEEN -0.55 AND 0.35) END)
FROM tmp_listing_typed GROUP BY city_code
UNION ALL
SELECT city_code, 'listings', 'R8 Duplicate listing_id',
       'Kept first occurrence', COUNT(*) - COUNT(DISTINCT listing_id)
FROM tmp_listing_typed GROUP BY city_code
UNION ALL
SELECT city_code, 'listings', 'R9 Multi-line / extra whitespace in listing name',
       'Collapsed to single spaces',
       SUM(s.name REGEXP '[\r\n\t]|  ') FROM stg_listings s GROUP BY city_code;

/* =====================================================================
   STEP 2 - CITY-LEVEL STATISTICS FOR OUTLIERS & IMPUTATION
   MySQL 8 has no MEDIAN()/PERCENTILE_CONT, so percentiles are derived
   with ROW_NUMBER() and COUNT() window functions.
   ===================================================================== */
DROP TABLE IF EXISTS tmp_city_stats;
CREATE TABLE tmp_city_stats AS
SELECT p.city_code,
       MIN(CASE WHEN p.rn >= CEIL(@outlier_pctl * p.n) THEN p.price_local END) AS price_p99_local,
       MIN(CASE WHEN p.rn >= CEIL(0.50 * p.n)          THEN p.price_local END) AS price_median_local
FROM (
    SELECT city_code, price_local,
           ROW_NUMBER() OVER (PARTITION BY city_code ORDER BY price_local) AS rn,
           COUNT(*)     OVER (PARTITION BY city_code)                      AS n
    FROM tmp_listing_typed
    WHERE price_local IS NOT NULL
) p
GROUP BY p.city_code;

DROP TABLE IF EXISTS tmp_city_minnights;
CREATE TABLE tmp_city_minnights AS
SELECT m.city_code,
       MIN(CASE WHEN m.rn >= CEIL(0.50 * m.n) THEN m.minimum_nights_raw END) AS median_min_nights
FROM (
    SELECT city_code, minimum_nights_raw,
           ROW_NUMBER() OVER (PARTITION BY city_code ORDER BY minimum_nights_raw) AS rn,
           COUNT(*)     OVER (PARTITION BY city_code)                             AS n
    FROM tmp_listing_typed
    WHERE minimum_nights_raw IS NOT NULL
) m
GROUP BY m.city_code;

INSERT INTO data_quality_log (city_code, table_name, rule_name, action_taken, rows_affected)
SELECT t.city_code, 'listings',
       CONCAT('R2 Price above city P99 (', c.price_p99_local, ' local)'),
       'Kept; price_status = Outlier; excluded from price & revenue KPIs',
       SUM(t.price_local > c.price_p99_local)
FROM tmp_listing_typed t JOIN tmp_city_stats c ON c.city_code = t.city_code
GROUP BY t.city_code, c.price_p99_local
UNION ALL
SELECT t.city_code, 'listings', 'R3 Price below USD floor',
       'Kept; price_status = Error-Low; excluded from price KPIs',
       SUM(t.price_local * IF(t.city_code = 'LON', @fx_gbp, 1) < @price_floor)
FROM tmp_listing_typed t GROUP BY t.city_code;

/* =====================================================================
   STEP 3 - DIMENSIONS
   ===================================================================== */

/* ---- dim_room_type ---- */
DROP TABLE IF EXISTS dim_room_type;
CREATE TABLE dim_room_type (
    room_type_id  TINYINT     PRIMARY KEY,
    room_type     VARCHAR(30) NOT NULL UNIQUE,
    sort_order    TINYINT     NOT NULL
);
INSERT INTO dim_room_type VALUES
 (1, 'Entire home/apt', 1), (2, 'Private room', 2), (3, 'Hotel room', 3), (4, 'Shared room', 4);

/* ---- dim_neighbourhood: official lookup + any neighbourhood only seen in listings ---- */
DROP TABLE IF EXISTS dim_neighbourhood;
CREATE TABLE dim_neighbourhood (
    neighbourhood_id  INT AUTO_INCREMENT PRIMARY KEY,
    city_code         CHAR(3)      NOT NULL,
    city_name         VARCHAR(30)  NOT NULL,
    borough           VARCHAR(100) NOT NULL,
    neighbourhood     VARCHAR(100) NOT NULL,
    in_official_list  TINYINT      NOT NULL DEFAULT 1,
    UNIQUE KEY uq_city_nbhd (city_code, neighbourhood)
);

INSERT INTO dim_neighbourhood (city_code, city_name, borough, neighbourhood, in_official_list)
SELECT n.city_code, c.city_name,
       CASE WHEN n.city_code = 'NYC' THEN TRIM(n.neighbourhood_group) ELSE TRIM(n.neighbourhood) END,
       TRIM(n.neighbourhood), 1
FROM stg_neighbourhoods n
JOIN dim_city c ON c.city_code = n.city_code
WHERE NULLIF(TRIM(n.neighbourhood), '') IS NOT NULL;

INSERT INTO dim_neighbourhood (city_code, city_name, borough, neighbourhood, in_official_list)
SELECT DISTINCT t.city_code, c.city_name, t.borough, t.neighbourhood, 0
FROM tmp_listing_typed t
JOIN dim_city c ON c.city_code = t.city_code
LEFT JOIN dim_neighbourhood d ON d.city_code = t.city_code AND d.neighbourhood = t.neighbourhood
WHERE d.neighbourhood_id IS NULL;

INSERT INTO data_quality_log (city_code, table_name, rule_name, action_taken, rows_affected)
SELECT city_code, 'neighbourhoods', 'R10 Neighbourhood in listings but not in lookup',
       'Added to dim_neighbourhood (in_official_list = 0)', COUNT(*)
FROM dim_neighbourhood WHERE in_official_list = 0 GROUP BY city_code;

/* ---- dim_host: one row per host across both cities ---- */
DROP TABLE IF EXISTS dim_host;
CREATE TABLE dim_host (
    host_id             BIGINT UNSIGNED PRIMARY KEY,
    host_name           VARCHAR(255),
    total_listings      INT     NOT NULL,
    nyc_listings        INT     NOT NULL,
    london_listings     INT     NOT NULL,
    operates_in_both    TINYINT NOT NULL,
    host_segment        VARCHAR(30) NOT NULL,
    host_segment_order  TINYINT NOT NULL
);

INSERT INTO dim_host
SELECT host_id,
       MAX(host_name),
       COUNT(*),
       SUM(city_code = 'NYC'),
       SUM(city_code = 'LON'),
       (SUM(city_code = 'NYC') > 0 AND SUM(city_code = 'LON') > 0),
       CASE WHEN COUNT(*) = 1  THEN 'Single-listing host'
            WHEN COUNT(*) < 10 THEN 'Multi-listing (2-9)'
            ELSE                    'Commercial (10+)' END,
       CASE WHEN COUNT(*) = 1 THEN 1 WHEN COUNT(*) < 10 THEN 2 ELSE 3 END
FROM (SELECT DISTINCT city_code, listing_id, host_id, host_name FROM tmp_listing_typed) x
GROUP BY host_id;

/* =====================================================================
   STEP 4 - FACT_LISTING  (cleaned + enriched with business metrics)
   ===================================================================== */
DROP TABLE IF EXISTS fact_listing;
CREATE TABLE fact_listing (
    listing_id              BIGINT UNSIGNED PRIMARY KEY,
    city_code               CHAR(3)        NOT NULL,
    neighbourhood_id        INT            NOT NULL,
    room_type_id            TINYINT        NOT NULL,
    host_id                 BIGINT UNSIGNED NOT NULL,
    listing_name            VARCHAR(600),
    latitude                DECIMAL(9,6),
    longitude               DECIMAL(9,6),
    geo_valid               TINYINT        NOT NULL,
    -- price
    price_local             DECIMAL(12,2),
    price_usd               DECIMAL(12,2),      -- NULL unless price_status = 'Valid'
    price_status            VARCHAR(12)    NOT NULL,
    price_band              VARCHAR(20)    NOT NULL,
    price_band_order        TINYINT        NOT NULL,
    -- stay rules
    minimum_nights          INT            NOT NULL,
    min_nights_imputed      TINYINT        NOT NULL,
    stay_policy             VARCHAR(30)    NOT NULL,
    -- demand
    number_of_reviews       INT            NOT NULL,
    reviews_ltm             INT            NOT NULL,
    reviews_per_month       DECIMAL(8,2)   NOT NULL,
    last_review_date        DATE,
    days_since_last_review  INT,
    -- supply
    availability_365        INT            NOT NULL,
    availability_band       VARCHAR(25)    NOT NULL,
    host_listings_in_city   INT            NOT NULL,
    license_status          VARCHAR(30)    NOT NULL,
    activity_status         VARCHAR(30)    NOT NULL,
    is_active               TINYINT        NOT NULL,
    -- estimated performance (Inside Airbnb "San Francisco model")
    est_stay_nights         DECIMAL(8,2)   NOT NULL,
    est_booked_nights_ltm   DECIMAL(8,1)   NOT NULL,
    est_occupancy_pct       DECIMAL(5,1)   NOT NULL,
    est_revenue_ltm_usd     DECIMAL(14,2),
    -- filled from the calendar by sp_refresh_calendar_agg() in script 03
    cal_days_available      SMALLINT,
    cal_fully_blocked       TINYINT,
    KEY ix_fl_city (city_code),
    KEY ix_fl_nbhd (neighbourhood_id),
    KEY ix_fl_host (host_id),
    KEY ix_fl_room (room_type_id)
);

INSERT INTO fact_listing
SELECT
    b.listing_id, b.city_code, b.neighbourhood_id, b.room_type_id, b.host_id,
    b.listing_name, b.latitude, b.longitude, b.geo_valid,
    b.price_local,
    CASE WHEN b.price_status = 'Valid' THEN ROUND(b.price_local * b.fx, 2) END        AS price_usd,
    b.price_status,
    CASE WHEN b.price_status <> 'Valid'           THEN 'No valid price'
         WHEN b.price_local * b.fx < 75           THEN 'Under $75'
         WHEN b.price_local * b.fx < 150          THEN '$75-149'
         WHEN b.price_local * b.fx < 250          THEN '$150-249'
         WHEN b.price_local * b.fx < 400          THEN '$250-399'
         ELSE                                          '$400+' END                    AS price_band,
    CASE WHEN b.price_status <> 'Valid'           THEN 6
         WHEN b.price_local * b.fx < 75           THEN 1
         WHEN b.price_local * b.fx < 150          THEN 2
         WHEN b.price_local * b.fx < 250          THEN 3
         WHEN b.price_local * b.fx < 400          THEN 4
         ELSE 5 END                                                                   AS price_band_order,
    b.min_nights,
    b.min_nights_imputed,
    CASE WHEN b.min_nights >= @long_stay THEN 'Long-term (30+ nights)'
         ELSE 'Short-term (<30 nights)' END                                           AS stay_policy,
    b.number_of_reviews,
    b.reviews_ltm,
    b.reviews_per_month,
    b.last_review_date,
    DATEDIFF(b.snapshot_date, b.last_review_date)                                     AS days_since_last_review,
    b.availability_365,
    CASE WHEN b.availability_365 = 0   THEN '0 days (blocked)'
         WHEN b.availability_365 <= 90 THEN '1-90 days'
         WHEN b.availability_365 <= 180 THEN '91-180 days'
         WHEN b.availability_365 <= 270 THEN '181-270 days'
         ELSE '271-365 days' END                                                      AS availability_band,
    b.host_listings_in_city,
    b.license_status,
    b.activity_status,
    (b.activity_status = 'Active')                                                    AS is_active,
    b.stay_nights                                                                     AS est_stay_nights,
    b.booked_nights                                                                   AS est_booked_nights_ltm,
    ROUND(b.booked_nights / 365 * 100, 1)                                             AS est_occupancy_pct,
    CASE WHEN b.price_status = 'Valid'
         THEN ROUND(b.booked_nights * b.price_local * b.fx, 2) END                    AS est_revenue_ltm_usd,
    NULL                                                                              AS cal_days_available,
    NULL                                                                              AS cal_fully_blocked
FROM (
    SELECT t.*,
           c.fx_to_usd   AS fx,
           c.snapshot_date,
           n.neighbourhood_id,
           r.room_type_id,
           CASE WHEN t.city_code = 'NYC'
                 THEN (t.latitude BETWEEN 40.40 AND 41.00 AND t.longitude BETWEEN -74.30 AND -73.60)
                 ELSE (t.latitude BETWEEN 51.25 AND 51.75 AND t.longitude BETWEEN -0.55 AND 0.35) END AS geo_valid,
           CASE WHEN t.price_local IS NULL                     THEN 'Missing'
                WHEN t.price_local > s.price_p99_local         THEN 'Outlier'
                WHEN t.price_local * c.fx_to_usd < @price_floor THEN 'Error-Low'
                ELSE 'Valid' END                                                      AS price_status,
           LEAST(COALESCE(t.minimum_nights_raw, m.median_min_nights), 365)            AS min_nights,
           (t.minimum_nights_raw IS NULL)                                             AS min_nights_imputed,
           COALESCE(t.reviews_per_month_raw, 0)                                       AS reviews_per_month,
           CASE WHEN t.city_code = 'LON'                    THEN 'N/A (no UK register)'
                WHEN t.license_raw IS NULL                  THEN 'No licence'
                WHEN t.license_raw = 'Exempt'               THEN 'Exempt'
                WHEN t.license_raw LIKE 'OSE-STRREG%'       THEN 'Registered (OSE)'
                ELSE 'Other / pending' END                                            AS license_status,
           CASE WHEN t.price_local IS NULL OR t.availability_365 = 0 THEN 'Inactive'
                WHEN t.reviews_ltm = 0                                 THEN 'Dormant (no reviews 12m)'
                ELSE 'Active' END                                                     AS activity_status,
           GREATEST(LEAST(COALESCE(t.minimum_nights_raw, m.median_min_nights), 365), @default_stay) AS stay_nights,
           ROUND(LEAST(t.reviews_ltm / @review_rate
                       * GREATEST(LEAST(COALESCE(t.minimum_nights_raw, m.median_min_nights), 365), @default_stay),
                       365 * @max_occ), 1)                                            AS booked_nights
    FROM tmp_listing_typed t
    JOIN dim_city            c ON c.city_code = t.city_code
    JOIN tmp_city_stats      s ON s.city_code = t.city_code
    JOIN tmp_city_minnights  m ON m.city_code = t.city_code
    JOIN dim_neighbourhood   n ON n.city_code = t.city_code AND n.neighbourhood = t.neighbourhood
    JOIN dim_room_type       r ON r.room_type = t.room_type
) b;

/* =====================================================================
   STEP 5 - FACT_REVIEW
   ===================================================================== */
DROP TABLE IF EXISTS fact_review;
CREATE TABLE fact_review (
    review_key   BIGINT AUTO_INCREMENT PRIMARY KEY,
    listing_id   BIGINT UNSIGNED NOT NULL,
    city_code    CHAR(3) NOT NULL,
    review_date  DATE    NOT NULL,
    review_month DATE    NOT NULL,
    is_simulated TINYINT NOT NULL DEFAULT 0,   -- 1 = row created by the real-time demo (script 03)
    KEY ix_fr_listing (listing_id),
    KEY ix_fr_city_month (city_code, review_month)
);

INSERT INTO data_quality_log (city_code, table_name, rule_name, action_taken, rows_affected)
SELECT r.city_code, 'reviews', 'R11 Unparseable / after scrape date / orphan reviews',
       'Removed',
       SUM(STR_TO_DATE(r.review_date, '%Y-%m-%d') IS NULL
           OR STR_TO_DATE(r.review_date, '%Y-%m-%d') > c.scrape_end_date
           OR f.listing_id IS NULL)
FROM stg_reviews r
JOIN dim_city c ON c.city_code = r.city_code
LEFT JOIN fact_listing f ON f.listing_id = CAST(r.listing_id AS UNSIGNED)
GROUP BY r.city_code;

INSERT INTO data_quality_log (city_code, table_name, rule_name, action_taken, rows_affected)
SELECT city_code, 'reviews', 'R12 Same listing + same date appears more than once',
       'Kept - legitimate multiple reviews per day (no review_id to dedupe on)',
       COUNT(*) - COUNT(DISTINCT listing_id, review_date)
FROM stg_reviews GROUP BY city_code;

INSERT INTO fact_review (listing_id, city_code, review_date, review_month, is_simulated)
SELECT f.listing_id, r.city_code,
       STR_TO_DATE(r.review_date, '%Y-%m-%d'),
       DATE_FORMAT(STR_TO_DATE(r.review_date, '%Y-%m-%d'), '%Y-%m-01'), 0
FROM stg_reviews r
JOIN dim_city     c ON c.city_code = r.city_code
JOIN fact_listing f ON f.listing_id = CAST(r.listing_id AS UNSIGNED)
WHERE STR_TO_DATE(r.review_date, '%Y-%m-%d') IS NOT NULL
  AND STR_TO_DATE(r.review_date, '%Y-%m-%d') <= c.scrape_end_date;

/* =====================================================================
   STEP 6 - FACT_CALENDAR  (clean in place, then promote - ELT style)
   Keep exactly 365 forward days per city and drop orphan listings.
   ===================================================================== */
INSERT INTO data_quality_log (city_code, table_name, rule_name, action_taken, rows_affected)
SELECT s.city_code, 'calendar', 'R13 Date outside snapshot + 365-day window',
       'Removed', COUNT(*)
FROM stg_calendar s JOIN dim_city c ON c.city_code = s.city_code
WHERE s.cal_date <  c.snapshot_date
   OR s.cal_date >= DATE_ADD(c.snapshot_date, INTERVAL 365 DAY)
GROUP BY s.city_code;

DELETE s FROM stg_calendar s JOIN dim_city c ON c.city_code = s.city_code
WHERE s.cal_date <  c.snapshot_date
   OR s.cal_date >= DATE_ADD(c.snapshot_date, INTERVAL 365 DAY);

INSERT INTO data_quality_log (city_code, table_name, rule_name, action_taken, rows_affected)
SELECT s.city_code, 'calendar', 'R14 Calendar rows for unknown listing', 'Removed', COUNT(*)
FROM stg_calendar s LEFT JOIN fact_listing f ON f.listing_id = s.listing_id
WHERE f.listing_id IS NULL GROUP BY s.city_code;

DELETE s FROM stg_calendar s LEFT JOIN fact_listing f ON f.listing_id = s.listing_id
WHERE f.listing_id IS NULL;

DROP TABLE IF EXISTS fact_calendar;
RENAME TABLE stg_calendar TO fact_calendar;

/* =====================================================================
   STEP 7 - HOUSEKEEPING + AUDIT
   ===================================================================== */
DROP TABLE IF EXISTS tmp_listing_typed;
DROP TABLE IF EXISTS tmp_city_minnights;
-- tmp_city_stats is kept: it documents the outlier thresholds used
RENAME TABLE tmp_city_stats TO ref_city_price_thresholds;

INSERT INTO etl_run_log (step_name, row_count, note)
SELECT '02 fact_listing',  COUNT(*), 'cleaned listings'        FROM fact_listing
UNION ALL SELECT '02 fact_review',   COUNT(*), 'cleaned reviews'  FROM fact_review
UNION ALL SELECT '02 fact_calendar', COUNT(*), 'cleaned calendar' FROM fact_calendar
UNION ALL SELECT '02 dim_host',      COUNT(*), 'hosts'            FROM dim_host
UNION ALL SELECT '02 dim_neighbourhood', COUNT(*), 'neighbourhoods' FROM dim_neighbourhood;

-- Review what the cleaning did
SELECT city_code, table_name, rule_name, action_taken, FORMAT(rows_affected, 0) AS rows_affected
FROM data_quality_log ORDER BY dq_id;


/* =====================================================================
   Script 03 : AGGREGATE LAYER + "REAL-TIME" REFRESH ENGINE
   ---------------------------------------------------------------------
   Why aggregates?  The calendar alone is ~44 M rows. Importing that into
   Power BI is slow and unnecessary; we push the heavy GROUP BY work down
   to the database (as Airbnb does in Hive/Spark) and give Power BI
   compact, pre-aggregated tables:
       dim_date                     calendar dimension 2009-2027
       agg_review_listing_month     reviews per listing per month   (~1.6 M rows)
       agg_calendar_listing_month   forward availability per listing per month
       kpi_snapshot                 time-stamped city KPIs (appended on every refresh)

   Real-time design
     sp_refresh_review_agg()       fast  - rebuild review aggregate
     sp_refresh_calendar_agg()     heavy - rebuild calendar aggregate (nightly)
     sp_capture_kpi_snapshot()     fast  - append a time-stamped KPI row per city
     sp_simulate_live_reviews()    demo  - inject new bookings/reviews "as they happen"
     ev_kpi_snapshot_15min         MySQL EVENT: snapshot every 15 minutes
     ev_nightly_full_refresh       MySQL EVENT: full refresh at 02:00
   Power BI (Import mode) then refreshes on a schedule via the gateway.
   ===================================================================== */

USE airbnb_analytics;

/* ---------- 1. DATE DIMENSION (no recursion needed) ----------------- */
DROP TABLE IF EXISTS dim_date;
CREATE TABLE dim_date (
    date_key       DATE PRIMARY KEY,
    year_num       SMALLINT    NOT NULL,
    quarter_label  CHAR(2)     NOT NULL,
    month_num      TINYINT     NOT NULL,
    month_name     VARCHAR(10) NOT NULL,
    month_short    CHAR(3)     NOT NULL,
    month_label    CHAR(7)     NOT NULL,
    month_start    DATE        NOT NULL,
    day_of_week    TINYINT     NOT NULL,   -- 1 = Monday
    day_name       VARCHAR(10) NOT NULL,
    is_weekend     TINYINT     NOT NULL,
    period_flag    VARCHAR(20) NOT NULL    -- Pre-COVID / COVID / Recovery / Post-LL18
);

INSERT INTO dim_date
SELECT d,
       YEAR(d),
       CONCAT('Q', QUARTER(d)),
       MONTH(d),
       MONTHNAME(d),
       LEFT(MONTHNAME(d), 3),
       DATE_FORMAT(d, '%Y-%m'),
       DATE_FORMAT(d, '%Y-%m-01'),
       WEEKDAY(d) + 1,
       DAYNAME(d),
       WEEKDAY(d) >= 5,
       CASE WHEN d <  '2020-03-01' THEN '1 Pre-COVID'
            WHEN d <  '2021-07-01' THEN '2 COVID'
            WHEN d <  '2023-09-05' THEN '3 Recovery'
            ELSE                        '4 Post-LL18' END
FROM (
    SELECT DATE_ADD('2009-01-01', INTERVAL (a.n + 10*b.n + 100*c.n + 1000*e.n) DAY) AS d
    FROM      (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
    CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
    CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
    CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
               UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) e
) days
WHERE d <= '2027-12-31';

/* ---------- 2. AGGREGATE TABLES ------------------------------------- */
DROP TABLE IF EXISTS agg_review_listing_month;
CREATE TABLE agg_review_listing_month (
    listing_id        BIGINT UNSIGNED NOT NULL,
    review_month      DATE            NOT NULL,
    city_code         CHAR(3)         NOT NULL,
    review_count      INT             NOT NULL,
    simulated_count   INT             NOT NULL,
    PRIMARY KEY (listing_id, review_month),
    KEY ix_arlm_city_month (city_code, review_month)
);

DROP TABLE IF EXISTS agg_calendar_listing_month;
CREATE TABLE agg_calendar_listing_month (
    listing_id         BIGINT UNSIGNED NOT NULL,
    month_start        DATE            NOT NULL,
    city_code          CHAR(3)         NOT NULL,
    days_in_window     SMALLINT        NOT NULL,
    days_available     SMALLINT        NOT NULL,
    days_unavailable   SMALLINT        NOT NULL,   -- booked OR host-blocked
    listing_fully_blocked TINYINT      NOT NULL,   -- 1 = zero open days in the next 365
    PRIMARY KEY (listing_id, month_start),
    KEY ix_aclm_city_month (city_code, month_start)
);

DROP TABLE IF EXISTS kpi_snapshot;
CREATE TABLE kpi_snapshot (
    snapshot_id          INT AUTO_INCREMENT PRIMARY KEY,
    captured_at          DATETIME     NOT NULL,
    city_code            CHAR(3)      NOT NULL,
    total_listings       INT          NOT NULL,
    active_listings      INT          NOT NULL,
    avg_price_usd        DECIMAL(10,2),
    total_reviews        BIGINT       NOT NULL,
    reviews_last_30d     INT          NOT NULL,
    simulated_reviews    INT          NOT NULL,
    est_revenue_ltm_usd  DECIMAL(16,2),
    fwd_unavailable_pct  DECIMAL(5,1),
    KEY ix_kpi_city_time (city_code, captured_at)
);

-- fact_listing.cal_days_available / cal_fully_blocked are created empty in script 02
-- and filled by sp_refresh_calendar_agg() below.

/* ---------- 3. PROCEDURES ------------------------------------------- */
DROP PROCEDURE IF EXISTS sp_refresh_review_agg;
DROP PROCEDURE IF EXISTS sp_refresh_calendar_agg;
DROP PROCEDURE IF EXISTS sp_capture_kpi_snapshot;
DROP PROCEDURE IF EXISTS sp_simulate_live_reviews;
DROP PROCEDURE IF EXISTS sp_clear_simulation;
DROP PROCEDURE IF EXISTS sp_refresh_all;

DELIMITER $$

CREATE PROCEDURE sp_refresh_review_agg()
BEGIN
    DECLARE v_rows BIGINT;
    TRUNCATE TABLE agg_review_listing_month;
    INSERT INTO agg_review_listing_month (listing_id, review_month, city_code, review_count, simulated_count)
    SELECT listing_id, review_month, city_code, COUNT(*), SUM(is_simulated)
    FROM fact_review
    GROUP BY listing_id, review_month, city_code;

    SELECT COUNT(*) INTO v_rows FROM agg_review_listing_month;
    INSERT INTO etl_run_log (step_name, row_count, note)
    VALUES ('sp_refresh_review_agg', v_rows, 'review aggregate rebuilt');
END$$

CREATE PROCEDURE sp_refresh_calendar_agg()
BEGIN
    DECLARE v_rows BIGINT;
    -- listing-level summary of the next 365 days
    DROP TEMPORARY TABLE IF EXISTS tmp_cal_listing;
    CREATE TEMPORARY TABLE tmp_cal_listing (PRIMARY KEY (listing_id)) AS
    SELECT listing_id,
           SUM(is_available)                 AS days_available,
           (SUM(is_available) = 0)           AS fully_blocked
    FROM fact_calendar
    GROUP BY listing_id;

    TRUNCATE TABLE agg_calendar_listing_month;
    INSERT INTO agg_calendar_listing_month
          (listing_id, month_start, city_code, days_in_window, days_available, days_unavailable, listing_fully_blocked)
    SELECT c.listing_id,
           DATE_FORMAT(c.cal_date, '%Y-%m-01') AS month_start,
           c.city_code,
           COUNT(*),
           SUM(c.is_available),
           COUNT(*) - SUM(c.is_available),
           MAX(t.fully_blocked)
    FROM fact_calendar c
    JOIN tmp_cal_listing t ON t.listing_id = c.listing_id
    GROUP BY c.listing_id, DATE_FORMAT(c.cal_date, '%Y-%m-01'), c.city_code;

    UPDATE fact_listing f
    LEFT JOIN tmp_cal_listing t ON t.listing_id = f.listing_id
    SET f.cal_days_available = t.days_available,
        f.cal_fully_blocked  = t.fully_blocked;

    SELECT COUNT(*) INTO v_rows FROM agg_calendar_listing_month;
    INSERT INTO etl_run_log (step_name, row_count, note)
    VALUES ('sp_refresh_calendar_agg', v_rows, 'calendar aggregate rebuilt');
END$$

CREATE PROCEDURE sp_capture_kpi_snapshot()
BEGIN
    DECLARE v_now DATETIME DEFAULT NOW();

    INSERT INTO kpi_snapshot (captured_at, city_code, total_listings, active_listings, avg_price_usd,
                              total_reviews, reviews_last_30d, simulated_reviews,
                              est_revenue_ltm_usd, fwd_unavailable_pct)
    SELECT v_now,
           l.city_code,
           l.total_listings,
           l.active_listings,
           l.avg_price_usd,
           COALESCE(r.total_reviews, 0),
           COALESCE(r.reviews_last_30d, 0),
           COALESCE(r.simulated_reviews, 0),
           l.est_revenue,
           cal.fwd_unavailable_pct
    FROM (SELECT city_code,
                 COUNT(*)                  AS total_listings,
                 SUM(is_active)            AS active_listings,
                 ROUND(AVG(price_usd), 2)  AS avg_price_usd,
                 SUM(est_revenue_ltm_usd)  AS est_revenue
          FROM fact_listing GROUP BY city_code) l
    LEFT JOIN (SELECT r.city_code,
                      COUNT(*) AS total_reviews,
                      -- 30 days up to the scrape date, plus any live (simulated) reviews arriving after it
                      SUM(r.review_date > DATE_SUB(c.scrape_end_date, INTERVAL 30 DAY)) AS reviews_last_30d,
                      SUM(r.is_simulated) AS simulated_reviews
               FROM fact_review r JOIN dim_city c ON c.city_code = r.city_code
               GROUP BY r.city_code) r ON r.city_code = l.city_code
    LEFT JOIN (SELECT city_code,
                      ROUND(SUM(days_unavailable) / SUM(days_in_window) * 100, 1) AS fwd_unavailable_pct
               FROM agg_calendar_listing_month
               WHERE listing_fully_blocked = 0
               GROUP BY city_code) cal ON cal.city_code = l.city_code;
END$$

/* Demo of real-time ingestion: inject p_n new reviews (= completed stays)
   for random active listings, timestamped today, then refresh aggregates. */
CREATE PROCEDURE sp_simulate_live_reviews(IN p_city CHAR(3), IN p_n INT)
BEGIN
    INSERT INTO fact_review (listing_id, city_code, review_date, review_month, is_simulated)
    SELECT listing_id, city_code, CURDATE(), DATE_FORMAT(CURDATE(), '%Y-%m-01'), 1
    FROM fact_listing
    WHERE city_code = p_city AND is_active = 1
    ORDER BY RAND()
    LIMIT p_n;

    CALL sp_refresh_review_agg();
    CALL sp_capture_kpi_snapshot();
END$$

CREATE PROCEDURE sp_clear_simulation()
BEGIN
    DELETE FROM fact_review WHERE is_simulated = 1;
    CALL sp_refresh_review_agg();
    CALL sp_capture_kpi_snapshot();
END$$

CREATE PROCEDURE sp_refresh_all()
BEGIN
    CALL sp_refresh_review_agg();
    CALL sp_refresh_calendar_agg();
    CALL sp_capture_kpi_snapshot();
END$$

DELIMITER ;

/* ---------- 4. FIRST BUILD ------------------------------------------ */
CALL sp_refresh_all();

/* ---------- 5. SCHEDULED EVENTS (needs the event scheduler ON) -------
   If SET GLOBAL fails for lack of privilege, add  event_scheduler=ON
   under [mysqld] in my.ini and restart the MySQL80 service.            */
SET GLOBAL event_scheduler = ON;

DROP EVENT IF EXISTS ev_kpi_snapshot_15min;
CREATE EVENT ev_kpi_snapshot_15min
    ON SCHEDULE EVERY 15 MINUTE
    DO CALL sp_capture_kpi_snapshot();

DROP EVENT IF EXISTS ev_nightly_full_refresh;
CREATE EVENT ev_nightly_full_refresh
    ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '02:00:00'))
    DO CALL sp_refresh_all();

INSERT INTO etl_run_log (step_name, note) VALUES ('03_aggregates_realtime', 'aggregates built, events scheduled');

SELECT * FROM kpi_snapshot ORDER BY snapshot_id DESC LIMIT 2;


/* =====================================================================
   Script 04 : SEMANTIC LAYER FOR POWER BI  (vw_pbi_* views)
   ---------------------------------------------------------------------
   Power BI connects ONLY to these views. That keeps the dashboard stable
   if the underlying tables change, and keeps the 44 M-row calendar out
   of the Power BI model.

   Star-schema relationships to build in Power BI (all single-direction,
   one-to-many, dimension -> fact):
     vw_pbi_dim_neighbourhood[neighbourhood_id] -> vw_pbi_fact_listing[neighbourhood_id]
     vw_pbi_dim_room_type[room_type_id]         -> vw_pbi_fact_listing[room_type_id]
     vw_pbi_dim_host[host_id]                   -> vw_pbi_fact_listing[host_id]
     vw_pbi_fact_listing[listing_id]            -> vw_pbi_fact_review_month[listing_id]
     vw_pbi_fact_listing[listing_id]            -> vw_pbi_fact_calendar_month[listing_id]
     vw_pbi_dim_date[date_key]                  -> vw_pbi_fact_review_month[review_month]
     vw_pbi_dim_date[date_key]                  -> vw_pbi_fact_calendar_month[month_start]
     vw_pbi_dim_city[city_code]                 -> vw_pbi_kpi_snapshot[city_code]
   ===================================================================== */

USE airbnb_analytics;

CREATE OR REPLACE VIEW vw_pbi_dim_city AS
SELECT city_code, city_name, country, local_currency, fx_to_usd,
       snapshot_date, scrape_end_date, regulation_note
FROM dim_city;

CREATE OR REPLACE VIEW vw_pbi_dim_neighbourhood AS
SELECT n.neighbourhood_id,
       n.city_code,
       n.city_name,
       n.borough,
       n.neighbourhood,
       CONCAT(n.city_name, ' | ', n.borough)  AS city_borough,
       -- Map-friendly location string for Power BI map visuals
       CASE WHEN n.city_code = 'NYC'
            THEN CONCAT(n.neighbourhood, ', ', n.borough, ', New York, USA')
            ELSE CONCAT(n.borough, ', London, United Kingdom') END AS map_location
FROM dim_neighbourhood n;

CREATE OR REPLACE VIEW vw_pbi_dim_room_type AS
SELECT room_type_id, room_type, sort_order FROM dim_room_type;

CREATE OR REPLACE VIEW vw_pbi_dim_host AS
SELECT host_id, host_name, total_listings, nyc_listings, london_listings,
       CASE WHEN operates_in_both = 1 THEN 'Both cities' ELSE 'One city' END AS host_footprint,
       host_segment, host_segment_order
FROM dim_host;

CREATE OR REPLACE VIEW vw_pbi_dim_date AS
SELECT date_key, year_num, quarter_label, month_num, month_name, month_short,
       month_label, month_start, day_of_week, day_name, is_weekend, period_flag
FROM dim_date;

CREATE OR REPLACE VIEW vw_pbi_fact_listing AS
SELECT f.listing_id,
       f.city_code,
       f.neighbourhood_id,
       f.room_type_id,
       f.host_id,
       f.listing_name,
       f.latitude,
       f.longitude,
       f.price_local,
       f.price_usd,
       f.price_status,
       f.price_band,
       f.price_band_order,
       f.minimum_nights,
       f.stay_policy,
       f.number_of_reviews,
       f.reviews_ltm,
       f.reviews_per_month,
       f.last_review_date,
       f.days_since_last_review,
       CASE WHEN f.last_review_date IS NULL           THEN '5 Never reviewed'
            WHEN f.days_since_last_review <= 90       THEN '1 0-3 months'
            WHEN f.days_since_last_review <= 365      THEN '2 3-12 months'
            WHEN f.days_since_last_review <= 1095     THEN '3 1-3 years'
            ELSE                                           '4 3+ years' END AS review_recency,
       f.availability_365,
       f.availability_band,
       f.host_listings_in_city,
       f.license_status,
       f.activity_status,
       f.is_active,
       f.est_booked_nights_ltm,
       f.est_occupancy_pct,
       f.est_revenue_ltm_usd,
       f.cal_days_available,
       f.cal_fully_blocked,
       CONCAT('https://www.airbnb.com/rooms/', f.listing_id) AS listing_url
FROM fact_listing f;

CREATE OR REPLACE VIEW vw_pbi_fact_review_month AS
SELECT listing_id, city_code, review_month, review_count, simulated_count
FROM agg_review_listing_month;

CREATE OR REPLACE VIEW vw_pbi_fact_calendar_month AS
SELECT listing_id, city_code, month_start, days_in_window, days_available,
       days_unavailable, listing_fully_blocked
FROM agg_calendar_listing_month;

-- Latest + historical KPI snapshots (drives the "live" page)
CREATE OR REPLACE VIEW vw_pbi_kpi_snapshot AS
SELECT k.*,
       (k.captured_at = (SELECT MAX(captured_at) FROM kpi_snapshot)) AS is_latest
FROM kpi_snapshot k;

CREATE OR REPLACE VIEW vw_pbi_data_quality AS
SELECT city_code, table_name, rule_name, action_taken, rows_affected, logged_at
FROM data_quality_log;

CREATE OR REPLACE VIEW vw_pbi_etl_log AS
SELECT run_id, step_name, row_count, started_at, note FROM etl_run_log;

/* ---------- Convenience summary views (also usable directly in SQL) -- */

-- City scorecard
CREATE OR REPLACE VIEW vw_city_scorecard AS
SELECT c.city_name,
       COUNT(*)                                                    AS total_listings,
       SUM(f.is_active)                                            AS active_listings,
       ROUND(100 * AVG(f.is_active), 1)                            AS active_pct,
       COUNT(DISTINCT f.host_id)                                   AS hosts,
       ROUND(AVG(f.price_usd), 0)                                  AS avg_price_usd,
       ROUND(100 * AVG(f.room_type_id = 1), 1)                     AS entire_home_pct,
       ROUND(100 * AVG(f.stay_policy LIKE 'Long-term%'), 1)        AS long_term_pct,
       SUM(f.reviews_ltm)                                          AS reviews_ltm,
       ROUND(AVG(CASE WHEN f.is_active = 1 THEN f.est_occupancy_pct END), 1) AS avg_est_occupancy_active,
       ROUND(SUM(f.est_revenue_ltm_usd) / 1e6, 1)                  AS est_revenue_ltm_usd_m
FROM fact_listing f
JOIN dim_city c ON c.city_code = f.city_code
GROUP BY c.city_name;

-- Borough scorecard with in-city ranking (window functions)
CREATE OR REPLACE VIEW vw_borough_scorecard AS
SELECT b.*,
       RANK() OVER (PARTITION BY b.city_name ORDER BY b.est_revenue_usd DESC) AS revenue_rank_in_city,
       ROUND(100 * b.listings / SUM(b.listings) OVER (PARTITION BY b.city_name), 1) AS share_of_city_listings_pct
FROM (
    SELECT n.city_name, n.borough,
           COUNT(*)                              AS listings,
           SUM(f.is_active)                      AS active_listings,
           ROUND(AVG(f.price_usd), 0)            AS avg_price_usd,
           ROUND(AVG(CASE WHEN f.is_active = 1 THEN f.est_occupancy_pct END), 1) AS avg_occupancy_active,
           COALESCE(SUM(f.est_revenue_ltm_usd), 0) AS est_revenue_usd
    FROM fact_listing f
    JOIN dim_neighbourhood n ON n.neighbourhood_id = f.neighbourhood_id
    GROUP BY n.city_name, n.borough
) b;

INSERT INTO etl_run_log (step_name, note) VALUES ('04_powerbi_views', 'semantic views created');

SELECT * FROM vw_city_scorecard;


/* =====================================================================
   Script 05 : ADVANCED ANALYTICAL SQL  -  NEW YORK vs LONDON
   ---------------------------------------------------------------------
   Each query answers one management question. Techniques used:
   multi-table JOINs, CTEs, conditional aggregation (pivoting),
   window functions (RANK, ROW_NUMBER, NTILE, LAG, running SUM),
   rolling windows, Pareto analysis and parameter-driven dynamic filters.
   All money is in USD (London converted at the rate in etl_parameter).
   ===================================================================== */

USE airbnb_analytics;

/* ---------------------------------------------------------------------
   Q1. CITY SCORECARD - How do the two markets compare at a glance?
   --------------------------------------------------------------------- */
SELECT * FROM vw_city_scorecard;


/* ---------------------------------------------------------------------
   Q2. ROOM-TYPE MIX & PRICE (pivot with conditional aggregation)
       Which product dominates each city, and what does it cost?
   --------------------------------------------------------------------- */
SELECT r.room_type,
       SUM(f.city_code = 'NYC')                                          AS nyc_listings,
       SUM(f.city_code = 'LON')                                          AS london_listings,
       ROUND(100 * SUM(f.city_code = 'NYC') / SUM(SUM(f.city_code = 'NYC')) OVER (), 1) AS nyc_mix_pct,
       ROUND(100 * SUM(f.city_code = 'LON') / SUM(SUM(f.city_code = 'LON')) OVER (), 1) AS london_mix_pct,
       ROUND(AVG(CASE WHEN f.city_code = 'NYC' THEN f.price_usd END), 0) AS nyc_avg_price_usd,
       ROUND(AVG(CASE WHEN f.city_code = 'LON' THEN f.price_usd END), 0) AS london_avg_price_usd
FROM fact_listing f
JOIN dim_room_type r ON r.room_type_id = f.room_type_id
GROUP BY r.room_type, r.sort_order
ORDER BY r.sort_order;


/* ---------------------------------------------------------------------
   Q3. MEDIAN PRICE BY CITY & ROOM TYPE
       MySQL 8 has no MEDIAN(): use ROW_NUMBER + COUNT window functions.
   --------------------------------------------------------------------- */
WITH ranked AS (
    SELECT f.city_code, r.room_type, f.price_usd,
           ROW_NUMBER() OVER (PARTITION BY f.city_code, r.room_type ORDER BY f.price_usd) AS rn,
           COUNT(*)     OVER (PARTITION BY f.city_code, r.room_type)                      AS n
    FROM fact_listing f
    JOIN dim_room_type r ON r.room_type_id = f.room_type_id
    WHERE f.price_status = 'Valid'
)
SELECT city_code, room_type, n AS priced_listings,
       ROUND(AVG(price_usd), 0) AS median_price_usd
FROM ranked
WHERE rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2))   -- middle value(s)
GROUP BY city_code, room_type, n
ORDER BY room_type, city_code;


/* ---------------------------------------------------------------------
   Q4. BOROUGH LEAGUE TABLE - top 5 boroughs per city by estimated revenue
   --------------------------------------------------------------------- */
SELECT city_name, revenue_rank_in_city AS rnk, borough, listings, share_of_city_listings_pct,
       avg_price_usd, avg_occupancy_active,
       ROUND(est_revenue_usd / 1e6, 1) AS est_revenue_usd_m
FROM vw_borough_scorecard
WHERE revenue_rank_in_city <= 5
ORDER BY city_name, revenue_rank_in_city;


/* ---------------------------------------------------------------------
   Q5. DEMAND TREND - annual reviews and year-on-year growth (LAG)
       2026 is compared on a like-for-like Jan-to-mid-Sep basis.
   --------------------------------------------------------------------- */
WITH yearly AS (
    SELECT city_code,
           YEAR(review_date) AS yr,
           COUNT(*)          AS reviews,
           SUM(DAYOFYEAR(review_date) <= 257) AS reviews_ytd_sep14   -- 257 = 14 Sep
    FROM fact_review
    WHERE is_simulated = 0 AND YEAR(review_date) >= 2017
    GROUP BY city_code, YEAR(review_date)
)
SELECT city_code, yr, reviews,
       ROUND(100 * (reviews / LAG(reviews) OVER (PARTITION BY city_code ORDER BY yr) - 1), 1) AS yoy_growth_pct,
       reviews_ytd_sep14,
       ROUND(100 * (reviews_ytd_sep14 / LAG(reviews_ytd_sep14) OVER (PARTITION BY city_code ORDER BY yr) - 1), 1)
           AS ytd_yoy_growth_pct
FROM yearly
ORDER BY city_code, yr;


/* ---------------------------------------------------------------------
   Q6. REGULATION IMPACT - NYC Local Law 18 (enforced 5-Sep-2023)
       Rolling 12-month reviews (window frame) in both cities, indexed
       to Aug-2023 = 100, to isolate the NYC policy shock.
   --------------------------------------------------------------------- */
WITH monthly AS (
    SELECT city_code, review_month, COUNT(*) AS reviews
    FROM fact_review
    WHERE is_simulated = 0 AND review_month BETWEEN '2021-09-01' AND '2026-08-01'
    GROUP BY city_code, review_month
),
rolling AS (
    SELECT city_code, review_month, reviews,
           SUM(reviews) OVER (PARTITION BY city_code ORDER BY review_month
                              ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS reviews_r12m
    FROM monthly
)
SELECT r.city_code, r.review_month, r.reviews, r.reviews_r12m,
       ROUND(100 * r.reviews_r12m / b.reviews_r12m, 1) AS index_aug2023_eq_100
FROM rolling r
JOIN rolling b ON b.city_code = r.city_code AND b.review_month = '2023-08-01'
WHERE r.review_month >= '2022-08-01' AND MONTH(r.review_month) IN (2, 8)
ORDER BY r.city_code, r.review_month;


/* ---------------------------------------------------------------------
   Q7. STAY-POLICY SPLIT - how much supply is short-term vs 30+ nights?
   --------------------------------------------------------------------- */
SELECT c.city_name, f.stay_policy,
       COUNT(*)                             AS listings,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY c.city_name), 1) AS pct_of_city,
       ROUND(AVG(f.price_usd), 0)           AS avg_price_usd,
       SUM(f.reviews_ltm)                   AS reviews_ltm,
       ROUND(SUM(f.est_revenue_ltm_usd) / 1e6, 1) AS est_revenue_usd_m
FROM fact_listing f
JOIN dim_city c ON c.city_code = f.city_code
GROUP BY c.city_name, f.stay_policy
ORDER BY c.city_name, f.stay_policy;


/* ---------------------------------------------------------------------
   Q8. NYC COMPLIANCE RISK - short-term listings without registration
   --------------------------------------------------------------------- */
SELECT f.license_status, f.stay_policy,
       COUNT(*)              AS listings,
       SUM(f.is_active)      AS active_listings,
       SUM(f.reviews_ltm)    AS reviews_ltm
FROM fact_listing f
WHERE f.city_code = 'NYC'
GROUP BY f.license_status, f.stay_policy
ORDER BY f.stay_policy, listings DESC;


/* ---------------------------------------------------------------------
   Q9. HOST CONCENTRATION - do professional operators dominate supply?
       NTILE(100) ranks hosts into percentiles by listing count.
   --------------------------------------------------------------------- */
WITH host_city AS (
    SELECT f.city_code, f.host_id,
           COUNT(*)                         AS listings,
           COALESCE(SUM(f.est_revenue_ltm_usd), 0) AS revenue
    FROM fact_listing f
    GROUP BY f.city_code, f.host_id
),
pct AS (
    SELECT h.*, NTILE(100) OVER (PARTITION BY city_code ORDER BY listings DESC, revenue DESC) AS host_percentile
    FROM host_city h
)
SELECT city_code,
       COUNT(*)                                                         AS hosts,
       ROUND(100 * SUM(CASE WHEN host_percentile = 1  THEN listings END) / SUM(listings), 1) AS top1pct_hosts_listing_share,
       ROUND(100 * SUM(CASE WHEN host_percentile <= 10 THEN listings END) / SUM(listings), 1) AS top10pct_hosts_listing_share,
       ROUND(100 * SUM(CASE WHEN host_percentile <= 10 THEN revenue END)  / SUM(revenue), 1)  AS top10pct_hosts_revenue_share,
       ROUND(100 * SUM(CASE WHEN listings = 1 THEN 1 ELSE 0 END) / COUNT(*), 1)              AS single_listing_hosts_pct
FROM pct
GROUP BY city_code;


/* ---------------------------------------------------------------------
   Q10. TOP OPERATORS - largest hosts, flagging those active in both cities
   --------------------------------------------------------------------- */
SELECT h.host_name, h.total_listings, h.nyc_listings, h.london_listings,
       IF(h.operates_in_both = 1, 'Both', 'One') AS footprint,
       ROUND(AVG(f.price_usd), 0)                AS avg_price_usd,
       ROUND(100 * AVG(f.stay_policy LIKE 'Long-term%'), 0) AS long_term_pct
FROM dim_host h
JOIN fact_listing f ON f.host_id = h.host_id
GROUP BY h.host_id, h.host_name, h.total_listings, h.nyc_listings, h.london_listings, h.operates_in_both
ORDER BY h.total_listings DESC
LIMIT 10;


/* ---------------------------------------------------------------------
   Q11. PRICE QUARTILES vs PERFORMANCE (NTILE)
        Do cheaper listings fill more nights? Where is revenue made?
   --------------------------------------------------------------------- */
WITH q AS (
    SELECT f.city_code, f.price_usd, f.est_occupancy_pct, f.est_revenue_ltm_usd,
           NTILE(4) OVER (PARTITION BY f.city_code ORDER BY f.price_usd) AS price_quartile
    FROM fact_listing f
    WHERE f.price_status = 'Valid' AND f.is_active = 1
)
SELECT city_code, CONCAT('Q', price_quartile) AS price_quartile,
       MIN(price_usd) AS from_usd, MAX(price_usd) AS to_usd,
       ROUND(AVG(est_occupancy_pct), 1)      AS avg_est_occupancy_pct,
       ROUND(AVG(est_revenue_ltm_usd), 0)    AS avg_revenue_per_listing_usd
FROM q
GROUP BY city_code, price_quartile
ORDER BY city_code, price_quartile;


/* ---------------------------------------------------------------------
   Q12. FORWARD SEASONALITY - share of next-365-day nights already
        booked or blocked, by month (fully-blocked listings excluded)
   --------------------------------------------------------------------- */
SELECT a.city_code, d.month_label,
       ROUND(100 * SUM(a.days_unavailable) / SUM(a.days_in_window), 1) AS unavailable_pct
FROM agg_calendar_listing_month a
JOIN dim_date d ON d.date_key = a.month_start
WHERE a.listing_fully_blocked = 0
GROUP BY a.city_code, d.month_label
ORDER BY a.city_code, d.month_label;


/* ---------------------------------------------------------------------
   Q13. NEIGHBOURHOOD OPPORTUNITY MATRIX
        Where is demand above the city average but supply below it?
        (classic BCG-style 2x2 on occupancy vs listing density)
   --------------------------------------------------------------------- */
WITH nb AS (
    SELECT n.city_code, n.borough, n.neighbourhood,
           COUNT(*)                                      AS listings,
           AVG(CASE WHEN f.is_active = 1 THEN f.est_occupancy_pct END) AS occ,
           AVG(f.price_usd)                              AS adr
    FROM fact_listing f
    JOIN dim_neighbourhood n ON n.neighbourhood_id = f.neighbourhood_id
    GROUP BY n.city_code, n.borough, n.neighbourhood
    HAVING SUM(f.is_active) >= 20                       -- enough active listings to be meaningful
),
city_avg AS (
    SELECT city_code, AVG(listings) AS avg_listings, AVG(occ) AS avg_occ FROM nb GROUP BY city_code
)
SELECT nb.city_code, nb.borough, nb.neighbourhood, nb.listings,
       ROUND(nb.occ, 1) AS est_occupancy_pct, ROUND(nb.adr, 0) AS avg_price_usd,
       CASE WHEN nb.occ >= ca.avg_occ AND nb.listings <  ca.avg_listings THEN 'Under-supplied (grow)'
            WHEN nb.occ >= ca.avg_occ AND nb.listings >= ca.avg_listings THEN 'Core (protect)'
            WHEN nb.occ <  ca.avg_occ AND nb.listings >= ca.avg_listings THEN 'Saturated (optimise)'
            ELSE 'Niche (monitor)' END AS quadrant
FROM nb JOIN city_avg ca ON ca.city_code = nb.city_code
ORDER BY nb.city_code, quadrant, est_occupancy_pct DESC;


/* ---------------------------------------------------------------------
   Q14. REVENUE PARETO - how many neighbourhoods make 80% of revenue?
        Running SUM() OVER (ORDER BY ...) gives the cumulative share.
   --------------------------------------------------------------------- */
WITH rev AS (
    SELECT n.city_code, n.neighbourhood, SUM(f.est_revenue_ltm_usd) AS revenue
    FROM fact_listing f
    JOIN dim_neighbourhood n ON n.neighbourhood_id = f.neighbourhood_id
    WHERE f.est_revenue_ltm_usd > 0
    GROUP BY n.city_code, n.neighbourhood
),
cum AS (
    SELECT city_code, neighbourhood, revenue,
           ROW_NUMBER() OVER (PARTITION BY city_code ORDER BY revenue DESC) AS rnk,
           COUNT(*)     OVER (PARTITION BY city_code)                       AS n_areas,
           SUM(revenue) OVER (PARTITION BY city_code ORDER BY revenue DESC
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(revenue) OVER (PARTITION BY city_code)                   AS cum_share
    FROM rev
)
SELECT city_code, MIN(n_areas) AS areas_with_revenue,
       MIN(CASE WHEN cum_share >= 0.8 THEN rnk END) AS areas_for_80pct_revenue,
       ROUND(100 * MIN(CASE WHEN cum_share >= 0.8 THEN rnk END) / MIN(n_areas), 1) AS pct_of_areas
FROM cum
GROUP BY city_code;


/* ---------------------------------------------------------------------
   Q15. DORMANT SUPPLY - listings that look live but show no recent demand
   --------------------------------------------------------------------- */
SELECT c.city_name, f.activity_status,
       COUNT(*) AS listings,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY c.city_name), 1) AS pct_of_city
FROM fact_listing f
JOIN dim_city c ON c.city_code = f.city_code
GROUP BY c.city_name, f.activity_status
ORDER BY c.city_name, listings DESC;


/* ---------------------------------------------------------------------
   Q16. DYNAMIC FILTER WITH A PREPARED STATEMENT
        Change the four variables and re-run - the same pattern Power BI
        slicers apply. NULL means "all".
   --------------------------------------------------------------------- */
SET @p_city      = 'LON';             -- 'NYC' | 'LON' | NULL
SET @p_room_type = 'Entire home/apt'; -- any room_type | NULL
SET @p_min_price = 100;               -- USD
SET @p_max_price = 400;               -- USD

SET @sql = '
SELECT n.borough,
       COUNT(*)                        AS listings,
       ROUND(AVG(f.price_usd), 0)      AS avg_price_usd,
       ROUND(AVG(f.est_occupancy_pct),1) AS avg_est_occupancy_pct,
       ROUND(SUM(f.est_revenue_ltm_usd) / 1e6, 2) AS est_revenue_usd_m
FROM fact_listing f
JOIN dim_neighbourhood n ON n.neighbourhood_id = f.neighbourhood_id
JOIN dim_room_type     r ON r.room_type_id     = f.room_type_id
WHERE (? IS NULL OR f.city_code = ?)
  AND (? IS NULL OR r.room_type = ?)
  AND f.price_usd BETWEEN ? AND ?
  AND f.is_active = 1
GROUP BY n.borough
ORDER BY est_revenue_usd_m DESC
LIMIT 10';

PREPARE stmt FROM @sql;
EXECUTE stmt USING @p_city, @p_city, @p_room_type, @p_room_type, @p_min_price, @p_max_price;
DEALLOCATE PREPARE stmt;


/* =====================================================================
   Script 06 : PARAMETERISED / DYNAMIC REPORTING PROCEDURES
   ---------------------------------------------------------------------
   Reusable "self-service" reports. Pass NULL to mean "all".
   Dynamic SQL is built only from WHITELISTED column names, so user
   input can never inject SQL.
   ===================================================================== */

USE airbnb_analytics;

DROP PROCEDURE IF EXISTS sp_market_snapshot;
DROP PROCEDURE IF EXISTS sp_top_areas;
DROP PROCEDURE IF EXISTS sp_compare_cities_by;

DELIMITER $$

/* ---------------------------------------------------------------------
   1. sp_market_snapshot - KPI block for any slice of the market
      CALL sp_market_snapshot('NYC', 'Private room', 'Brooklyn', 50, 300);
      CALL sp_market_snapshot(NULL, NULL, NULL, NULL, NULL);
   --------------------------------------------------------------------- */
CREATE PROCEDURE sp_market_snapshot(
    IN p_city       CHAR(3),
    IN p_room_type  VARCHAR(30),
    IN p_borough    VARCHAR(100),
    IN p_min_price  DECIMAL(10,2),
    IN p_max_price  DECIMAL(10,2))
BEGIN
    SELECT c.city_name,
           COUNT(*)                                       AS listings,
           SUM(f.is_active)                               AS active_listings,
           ROUND(AVG(f.price_usd), 0)                     AS avg_price_usd,
           ROUND(AVG(CASE WHEN f.is_active = 1 THEN f.est_occupancy_pct END), 1) AS avg_est_occupancy_pct,
           SUM(f.reviews_ltm)                             AS reviews_ltm,
           ROUND(SUM(f.est_revenue_ltm_usd) / 1e6, 2)     AS est_revenue_usd_m,
           ROUND(100 * AVG(h.host_segment = 'Commercial (10+)'), 1) AS commercial_host_listing_pct
    FROM fact_listing f
    JOIN dim_city          c ON c.city_code        = f.city_code
    JOIN dim_neighbourhood n ON n.neighbourhood_id = f.neighbourhood_id
    JOIN dim_room_type     r ON r.room_type_id     = f.room_type_id
    JOIN dim_host          h ON h.host_id          = f.host_id
    WHERE (p_city      IS NULL OR f.city_code = p_city)
      AND (p_room_type IS NULL OR r.room_type = p_room_type)
      AND (p_borough   IS NULL OR n.borough   = p_borough)
      AND (p_min_price IS NULL OR f.price_usd >= p_min_price)
      AND (p_max_price IS NULL OR f.price_usd <= p_max_price)
    GROUP BY c.city_name;
END$$

/* ---------------------------------------------------------------------
   2. sp_top_areas - Top-N neighbourhoods by a chosen metric (dynamic ORDER BY)
      CALL sp_top_areas('LON', 'revenue', 10);
      p_metric: 'revenue' | 'listings' | 'price' | 'occupancy' | 'reviews'
   --------------------------------------------------------------------- */
CREATE PROCEDURE sp_top_areas(IN p_city CHAR(3), IN p_metric VARCHAR(20), IN p_top_n INT)
BEGIN
    DECLARE v_order VARCHAR(40);

    SET v_order = CASE LOWER(p_metric)
                    WHEN 'revenue'   THEN 'est_revenue_usd'
                    WHEN 'listings'  THEN 'listings'
                    WHEN 'price'     THEN 'avg_price_usd'
                    WHEN 'occupancy' THEN 'avg_est_occupancy_pct'
                    WHEN 'reviews'   THEN 'reviews_ltm'
                  END;

    IF v_order IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'p_metric must be revenue, listings, price, occupancy or reviews';
    END IF;

    SET @sql = CONCAT(
        'SELECT n.city_name, n.borough, n.neighbourhood, ',
        '       COUNT(*) AS listings, ',
        '       ROUND(AVG(f.price_usd), 0) AS avg_price_usd, ',
        '       ROUND(AVG(CASE WHEN f.is_active = 1 THEN f.est_occupancy_pct END), 1) AS avg_est_occupancy_pct, ',
        '       SUM(f.reviews_ltm) AS reviews_ltm, ',
        '       ROUND(COALESCE(SUM(f.est_revenue_ltm_usd), 0), 0) AS est_revenue_usd ',
        'FROM fact_listing f ',
        'JOIN dim_neighbourhood n ON n.neighbourhood_id = f.neighbourhood_id ',
        'WHERE (? IS NULL OR f.city_code = ?) ',
        'GROUP BY n.city_name, n.borough, n.neighbourhood ',
        'HAVING COUNT(*) >= 20 ',
        'ORDER BY ', v_order, ' DESC ',
        'LIMIT ?');

    SET @p_city = p_city, @p_n = p_top_n;
    PREPARE stmt FROM @sql;
    EXECUTE stmt USING @p_city, @p_city, @p_n;
    DEALLOCATE PREPARE stmt;
END$$

/* ---------------------------------------------------------------------
   3. sp_compare_cities_by - NYC vs London side by side on any dimension
      (dynamic GROUP BY)
      CALL sp_compare_cities_by('room_type');
      p_dimension: 'room_type' | 'price_band' | 'host_segment' |
                   'stay_policy' | 'availability_band' | 'activity_status'
   --------------------------------------------------------------------- */
CREATE PROCEDURE sp_compare_cities_by(IN p_dimension VARCHAR(30))
BEGIN
    DECLARE v_col VARCHAR(40);

    SET v_col = CASE LOWER(p_dimension)
                  WHEN 'room_type'         THEN 'r.room_type'
                  WHEN 'price_band'        THEN 'f.price_band'
                  WHEN 'host_segment'      THEN 'h.host_segment'
                  WHEN 'stay_policy'       THEN 'f.stay_policy'
                  WHEN 'availability_band' THEN 'f.availability_band'
                  WHEN 'activity_status'   THEN 'f.activity_status'
                END;

    IF v_col IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unsupported dimension';
    END IF;

    SET @sql = CONCAT(
        'SELECT ', v_col, ' AS segment, ',
        '  SUM(f.city_code = ''NYC'') AS nyc_listings, ',
        '  SUM(f.city_code = ''LON'') AS london_listings, ',
        '  ROUND(100 * SUM(f.city_code = ''NYC'') / SUM(SUM(f.city_code = ''NYC'')) OVER (), 1) AS nyc_pct, ',
        '  ROUND(100 * SUM(f.city_code = ''LON'') / SUM(SUM(f.city_code = ''LON'')) OVER (), 1) AS london_pct, ',
        '  ROUND(AVG(CASE WHEN f.city_code = ''NYC'' THEN f.price_usd END), 0) AS nyc_avg_price_usd, ',
        '  ROUND(AVG(CASE WHEN f.city_code = ''LON'' THEN f.price_usd END), 0) AS london_avg_price_usd ',
        'FROM fact_listing f ',
        'JOIN dim_room_type r ON r.room_type_id = f.room_type_id ',
        'JOIN dim_host      h ON h.host_id      = f.host_id ',
        'GROUP BY ', v_col, ' ',
        'ORDER BY nyc_listings + london_listings DESC');

    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END$$

DELIMITER ;

INSERT INTO etl_run_log (step_name, note) VALUES ('06_dynamic_procedures', 'reporting procedures created');

-- Examples
CALL sp_market_snapshot(NULL, 'Entire home/apt', NULL, NULL, NULL);
CALL sp_top_areas('NYC', 'revenue', 5);
CALL sp_compare_cities_by('host_segment');
