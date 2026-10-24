-- =====================================================================
-- RegRadar | 03_silver_build.sql
-- SILVER layer
-- Cleans bronze into typed, deduplicated tables, links IDs across sources,
-- and assigns every location point to a Boston neighborhood.
-- Run in Snowsight with Run All. Safe to re-run (full rebuild).
-- =====================================================================
USE WAREHOUSE REGRADAR_WH;
USE DATABASE REGRADAR_DB;
USE SCHEMA SILVER;

-- ---------------------------------------------------------------------
-- A. REGULATIONS
-- ---------------------------------------------------------------------

-- One row per Federal Register document (latest load wins if duplicated)
CREATE OR REPLACE TABLE RULES AS
SELECT
  payload:document_number::STRING                      AS document_number,
  payload:title::STRING                                AS title,
  payload:type::STRING                                 AS document_type,
  payload:action::STRING                               AS action,
  payload:abstract::STRING                             AS abstract,
  TRY_TO_DATE(payload:publication_date::STRING)        AS publication_date,
  TRY_TO_DATE(payload:effective_on::STRING)            AS effective_date,
  TRY_TO_DATE(payload:comments_close_on::STRING)       AS comments_close_date,
  COALESCE(payload:significant::BOOLEAN, FALSE)        AS is_significant,
  payload:regulation_id_numbers[0]::STRING             AS primary_rin,
  COALESCE(ARRAY_SIZE(payload:regulation_id_numbers), 0) AS rin_count,
  COALESCE(ARRAY_SIZE(payload:docket_ids), 0)          AS docket_count,
  COALESCE(ARRAY_SIZE(payload:cfr_references), 0)      AS cfr_reference_count,
  COALESCE(ARRAY_SIZE(payload:agencies), 0)            AS agency_count,
  payload:topics                                       AS topics,
  payload:html_url::STRING                             AS html_url,
  payload:raw_text_url::STRING                         AS raw_text_url,
  loaded_at
FROM BRONZE.RAW_FEDERAL_REGISTER
WHERE payload:document_number IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY payload:document_number::STRING ORDER BY loaded_at DESC) = 1;

-- Rule <-> agency (many-to-many), keeping the listed order (1 = primary)
CREATE OR REPLACE TABLE RULE_AGENCIES AS
SELECT
  r.payload:document_number::STRING                    AS document_number,
  a.index + 1                                          AS agency_order,
  a.value:id::NUMBER                                   AS fr_agency_id,
  COALESCE(a.value:slug::STRING,
           LOWER(REGEXP_REPLACE(COALESCE(a.value:name::STRING, a.value:raw_name::STRING), '[^A-Za-z]+', '-')))
                                                       AS agency_slug,
  COALESCE(a.value:name::STRING, a.value:raw_name::STRING) AS agency_name,
  a.value:parent_id::NUMBER                            AS parent_fr_agency_id
FROM BRONZE.RAW_FEDERAL_REGISTER r,
     LATERAL FLATTEN(input => r.payload:agencies) a
QUALIFY ROW_NUMBER() OVER (PARTITION BY document_number, agency_slug ORDER BY a.index) = 1;

-- Rule <-> CFR part (only references that name a specific part)
CREATE OR REPLACE TABLE RULE_CFR_PARTS AS
SELECT DISTINCT
  r.payload:document_number::STRING                    AS document_number,
  c.value:title::NUMBER                                AS cfr_title,
  c.value:part::STRING                                 AS cfr_part,
  c.value:title::STRING || ' CFR ' || c.value:part::STRING AS cfr_citation
FROM BRONZE.RAW_FEDERAL_REGISTER r,
     LATERAL FLATTEN(input => r.payload:cfr_references) c
WHERE c.value:part::STRING IS NOT NULL       -- ::STRING first: a JSON null is not a SQL NULL
  AND c.value:title::STRING IS NOT NULL;     -- skips references to a whole title or chapter

-- Rule <-> docket
CREATE OR REPLACE TABLE RULE_DOCKETS AS
SELECT DISTINCT
  r.payload:document_number::STRING                    AS document_number,
  d.value::STRING                                      AS docket_id
FROM BRONZE.RAW_FEDERAL_REGISTER r,
     LATERAL FLATTEN(input => r.payload:docket_ids) d;

-- Rule <-> RIN, with a format check (catches entries like OMB control numbers)
CREATE OR REPLACE TABLE RULE_RINS AS
SELECT DISTINCT
  r.payload:document_number::STRING                    AS document_number,
  n.value::STRING                                      AS rin,
  REGEXP_LIKE(n.value::STRING, '[0-9]{4}-[A-Z]{2}[0-9A-Z]{2}') AS is_valid_format
FROM BRONZE.RAW_FEDERAL_REGISTER r,
     LATERAL FLATTEN(input => r.payload:regulation_id_numbers) n;

-- Regulations.gov documents (comment dates converted to Eastern time, which is how deadlines are set)
CREATE OR REPLACE TABLE REGS_GOV_DOCUMENTS AS
SELECT
  payload:id::STRING                                   AS regs_gov_id,
  payload:frDocNum::STRING                             AS fr_doc_num,
  payload:docketId::STRING                             AS docket_id,
  payload:agencyId::STRING                             AS agency_id,
  payload:documentType::STRING                         AS document_type,
  payload:title::STRING                                AS title,
  CONVERT_TIMEZONE('America/New_York', TRY_TO_TIMESTAMP_TZ(payload:postedDate::STRING))::DATE       AS posted_date,
  CONVERT_TIMEZONE('America/New_York', TRY_TO_TIMESTAMP_TZ(payload:commentStartDate::STRING))::DATE AS comment_start_date,
  CONVERT_TIMEZONE('America/New_York', TRY_TO_TIMESTAMP_TZ(payload:commentEndDate::STRING))::DATE   AS comment_end_date,
  COALESCE(payload:openForComment::BOOLEAN, FALSE)     AS open_for_comment,
  loaded_at
FROM BRONZE.RAW_REGULATIONS_GOV
QUALIFY ROW_NUMBER() OVER (PARTITION BY payload:id::STRING ORDER BY loaded_at DESC) = 1;

-- One row per agency, with its parent and its Regulations.gov acronym
-- (acronym = the agencyId most often seen on matched documents where that agency is primary)
CREATE OR REPLACE TABLE AGENCIES AS
WITH base AS (
  SELECT agency_slug,
         MAX(fr_agency_id)        AS fr_agency_id,
         MAX(agency_name)         AS agency_name,
         MAX(parent_fr_agency_id) AS parent_fr_agency_id
  FROM RULE_AGENCIES
  GROUP BY agency_slug
),
acr AS (
  SELECT ra.agency_slug, MODE(rg.agency_id) AS agency_acronym
  FROM RULE_AGENCIES ra
  JOIN REGS_GOV_DOCUMENTS rg ON rg.fr_doc_num = ra.document_number
  WHERE ra.agency_order = 1
  GROUP BY ra.agency_slug
)
SELECT b.agency_slug, b.fr_agency_id, b.agency_name,
       acr.agency_acronym,
       p.agency_name AS parent_agency_name
FROM base b
LEFT JOIN acr ON acr.agency_slug = b.agency_slug
LEFT JOIN base p ON p.fr_agency_id = b.parent_fr_agency_id;

-- The ID crosswalk: every identifier for each rule, in one place
CREATE OR REPLACE TABLE ID_CROSSWALK AS
WITH rins AS (SELECT document_number, ARRAY_AGG(DISTINCT rin) AS rins FROM RULE_RINS GROUP BY 1),
     dk   AS (SELECT document_number, ARRAY_AGG(DISTINCT docket_id) AS docket_ids FROM RULE_DOCKETS GROUP BY 1),
     cfr  AS (SELECT document_number, ARRAY_AGG(DISTINCT cfr_citation) AS cfr_citations FROM RULE_CFR_PARTS GROUP BY 1),
     rg   AS (SELECT fr_doc_num, ARRAY_AGG(DISTINCT regs_gov_id) AS regs_gov_ids,
                     MIN(comment_start_date) AS comment_start_date, MAX(comment_end_date) AS comment_end_date,
                     BOOLOR_AGG(open_for_comment) AS open_for_comment
              FROM REGS_GOV_DOCUMENTS WHERE fr_doc_num IS NOT NULL GROUP BY 1)
SELECT r.document_number, r.document_type, r.publication_date,
       rins.rins, dk.docket_ids, cfr.cfr_citations, rg.regs_gov_ids,
       rg.comment_start_date, rg.comment_end_date,
       COALESCE(rg.open_for_comment, FALSE) AS open_for_comment,
       rg.fr_doc_num IS NOT NULL            AS matched_to_regs_gov
FROM RULES r
LEFT JOIN rins ON rins.document_number = r.document_number
LEFT JOIN dk   ON dk.document_number   = r.document_number
LEFT JOIN cfr  ON cfr.document_number  = r.document_number
LEFT JOIN rg   ON rg.fr_doc_num        = r.document_number;

-- eCFR section versions (feeds Type 2 history and the CFR change fact)
CREATE OR REPLACE TABLE CFR_VERSIONS AS
SELECT
  payload:cfr_title::NUMBER                            AS cfr_title,
  payload:cfr_part::STRING                             AS cfr_part,
  payload:cfr_title::STRING || ' CFR ' || payload:cfr_part::STRING AS cfr_citation,
  payload:identifier::STRING                           AS section_identifier,
  payload:name::STRING                                 AS section_name,
  payload:subpart::STRING                              AS subpart,
  payload:type::STRING                                 AS version_type,
  TRY_TO_DATE(payload:date::STRING)                    AS version_date,
  TRY_TO_DATE(payload:amendment_date::STRING)          AS amendment_date,
  TRY_TO_DATE(payload:issue_date::STRING)              AS issue_date,
  COALESCE(payload:substantive::BOOLEAN, FALSE)        AS is_substantive,
  COALESCE(payload:removed::BOOLEAN, FALSE)            AS is_removed
FROM BRONZE.RAW_ECFR_VERSIONS;

-- Current full text of each CFR part (kept for chunking and search later)
CREATE OR REPLACE TABLE CFR_PART_TEXT AS
SELECT
  payload:cfr_title::NUMBER                            AS cfr_title,
  payload:cfr_part::STRING                             AS cfr_part,
  payload:cfr_title::STRING || ' CFR ' || payload:cfr_part::STRING AS cfr_citation,
  TRY_TO_DATE(payload:as_of::STRING)                   AS text_as_of,
  payload:xml::STRING                                  AS xml_text,
  LENGTH(payload:xml::STRING)                          AS characters
FROM BRONZE.RAW_ECFR;

-- Federal bills
CREATE OR REPLACE TABLE BILLS AS
SELECT
  payload:congress::STRING || '-' || payload:type::STRING || '-' || payload:number::STRING AS bill_id,
  payload:congress::NUMBER                             AS congress,
  payload:type::STRING                                 AS bill_type,
  payload:number::STRING                               AS bill_number,
  payload:title::STRING                                AS title,
  payload:originChamber::STRING                        AS origin_chamber,
  TRY_TO_DATE(payload:latestAction:actionDate::STRING) AS latest_action_date,
  payload:latestAction:text::STRING                    AS latest_action_text,
  TRY_TO_DATE(LEFT(payload:updateDate::STRING, 10))    AS update_date,
  payload:url::STRING                                  AS bill_url,
  REGEXP_INSTR(LOWER(payload:title::STRING),
    'small business|restaurant|construction|retail|worker|wage|osha|food|employer|tax credit') > 0
                                                       AS is_small_business_relevant
FROM BRONZE.RAW_CONGRESS
QUALIFY ROW_NUMBER() OVER (PARTITION BY bill_id ORDER BY loaded_at DESC) = 1;

-- Massachusetts regulations
CREATE OR REPLACE TABLE MA_REGULATIONS AS
SELECT
  payload:citation::STRING                             AS citation,
  payload:source_file::STRING                          AS source_file,
  payload:pages::NUMBER                                AS pages,
  payload:characters::NUMBER                           AS characters,
  payload:text::STRING                                 AS full_text
FROM BRONZE.RAW_MA_REGULATIONS;

-- ---------------------------------------------------------------------
-- B. INDUSTRY
-- ---------------------------------------------------------------------

-- NAICS with the hierarchy flattened. Some sectors are ranges (31-33, 44-45, 48-49).
CREATE OR REPLACE TABLE NAICS AS
WITH n AS (
  SELECT
    payload:naics_code::STRING                         AS naics_code,
    payload:naics_title::STRING                        AS naics_title,
    TRY_TO_NUMBER(payload:level::STRING)               AS naics_level,
    NULLIF(payload:demo_industry::STRING, '')          AS demo_industry
  FROM BRONZE.RAW_NAICS
),
s AS (
  SELECT n.*,
         CASE LEFT(naics_code, 2)
           WHEN '31' THEN '31-33' WHEN '32' THEN '31-33' WHEN '33' THEN '31-33'
           WHEN '44' THEN '44-45' WHEN '45' THEN '44-45'
           WHEN '48' THEN '48-49' WHEN '49' THEN '48-49'
           ELSE LEFT(naics_code, 2) END                AS sector_code
  FROM n
)
SELECT s.naics_code, s.naics_title, s.naics_level, s.sector_code,
       sec.naics_title                                 AS sector_title,
       IFF(s.naics_level >= 3, LEFT(s.naics_code, 3), NULL) AS subsector_code,
       IFF(s.naics_level >= 4, LEFT(s.naics_code, 4), NULL) AS industry_group_code,
       s.demo_industry,
       '2022'                                          AS naics_version
FROM s
LEFT JOIN n sec ON sec.naics_code = s.sector_code;

-- ---------------------------------------------------------------------
-- C. LOCATION (everything gets a neighborhood through a point-in-polygon check)
-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE NEIGHBORHOODS AS
WITH g AS (
  SELECT
    COALESCE(payload:properties:name::STRING, payload:properties:Name::STRING,
             payload:properties:NAME::STRING, payload:properties:neighborhood::STRING,
             payload:properties:Neighborhood::STRING, payload:properties:blockgr2020_neighborhood::STRING)
                                                       AS neighborhood_name,
    TRY_TO_GEOGRAPHY(TO_JSON(payload:geometry), TRUE)  AS geog
  FROM BRONZE.RAW_BOSTON_NEIGHBORHOODS
)
SELECT neighborhood_name, geog,
       ROUND(ST_AREA(geog) / 2589988.11, 2)            AS area_sq_miles,
       ST_Y(ST_CENTROID(geog))                         AS centroid_lat,
       ST_X(ST_CENTROID(geog))                         AS centroid_lon
FROM g;

CREATE OR REPLACE TABLE CENSUS_TRACTS AS
WITH t AS (
  SELECT
    payload:geoid::STRING                              AS geoid,
    payload:NAME::STRING                               AS tract_name,
    TRY_TO_NUMBER(payload:population::STRING)          AS population,
    TRY_TO_NUMBER(payload:age_18_34::STRING)           AS age_18_34,
    TRY_TO_NUMBER(payload:median_income::STRING)       AS median_income,
    TRY_TO_DOUBLE(payload:median_age::STRING)          AS median_age,
    TRY_TO_DOUBLE(payload:lat::STRING)                 AS lat,
    TRY_TO_DOUBLE(payload:lon::STRING)                 AS lon
  FROM BRONZE.RAW_CENSUS_ACS
)
SELECT t.*, n.neighborhood_name
FROM t
LEFT JOIN NEIGHBORHOODS n ON ST_CONTAINS(n.geog, ST_MAKEPOINT(t.lon, t.lat))
QUALIFY ROW_NUMBER() OVER (PARTITION BY t.geoid ORDER BY n.neighborhood_name) = 1;

CREATE OR REPLACE TABLE COLLEGES AS
WITH c AS (
  SELECT
    payload:id::STRING                                 AS college_id,
    payload['school.name']::STRING                     AS college_name,
    payload['school.city']::STRING                     AS city,
    LEFT(payload['school.zip']::STRING, 5)             AS zip_code,
    payload['location.lat']::DOUBLE                    AS lat,
    payload['location.lon']::DOUBLE                    AS lon,
    COALESCE(payload['latest.student.size']::NUMBER, 0)          AS undergrad_students,
    COALESCE(payload['latest.student.grad_students']::NUMBER, 0) AS grad_students
  FROM BRONZE.RAW_COLLEGES
)
SELECT c.*, c.undergrad_students + c.grad_students AS total_students, n.neighborhood_name
FROM c
LEFT JOIN NEIGHBORHOODS n ON ST_CONTAINS(n.geog, ST_MAKEPOINT(c.lon, c.lat))
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.college_id ORDER BY n.neighborhood_name) = 1;

CREATE OR REPLACE TABLE MBTA_STATIONS AS
WITH s AS (
  SELECT
    payload:station_id::STRING                         AS station_id,
    payload:name::STRING                               AS station_name,
    payload:municipality::STRING                       AS municipality,
    payload:lat::DOUBLE                                AS lat,
    payload:lon::DOUBLE                                AS lon,
    payload:lines                                      AS lines,
    ARRAY_SIZE(payload:lines)                          AS line_count
  FROM BRONZE.RAW_MBTA_STATIONS
)
SELECT s.*, n.neighborhood_name
FROM s
LEFT JOIN NEIGHBORHOODS n ON ST_CONTAINS(n.geog, ST_MAKEPOINT(s.lon, s.lat))
QUALIFY ROW_NUMBER() OVER (PARTITION BY s.station_id ORDER BY n.neighborhood_name) = 1;

CREATE OR REPLACE TABLE BUSINESS_COUNTS AS
SELECT
  LPAD(payload:zip::STRING, 5, '0')                    AS zip_code,
  payload:naics_code::STRING                           AS naics_code,
  payload:industry::STRING                             AS industry,
  TRY_TO_NUMBER(payload:establishments::STRING)        AS establishments,
  TRY_TO_NUMBER(REGEXP_SUBSTR(source_file, 'boston_([0-9]{4})_', 1, 1, 'e', 1)) AS data_year
FROM BRONZE.RAW_BUSINESS_PATTERNS;

-- Food establishments. Industry is mapped roughly: retail food -> 4451 (grocery), everything else -> 7225 (eating places)
CREATE OR REPLACE TABLE FOOD_ESTABLISHMENTS AS
WITH f AS (
  SELECT
    COALESCE(NULLIF(payload:licenseno::STRING, ''),
             MD5(COALESCE(payload:businessname::STRING, '') || '|' || COALESCE(payload:address::STRING, '')))
                                                       AS establishment_id,
    payload:businessname::STRING                       AS business_name,
    NULLIF(payload:dbaname::STRING, '')                AS dba_name,
    payload:address::STRING                            AS address,
    LPAD(NULLIF(SPLIT_PART(payload:zip::STRING, '.', 1), ''), 5, '0') AS zip_code,
    payload:licstatus::STRING                          AS license_status,
    payload:licensecat::STRING                         AS license_category,
    payload:descript::STRING                           AS description,
    TRY_TO_DATE(LEFT(payload:license_add_dt_tm::STRING, 10)) AS license_added_date,
    TRY_TO_DOUBLE(COALESCE(payload:latitude::STRING, payload:lat::STRING, payload:y::STRING))  AS lat,
    TRY_TO_DOUBLE(COALESCE(payload:longitude::STRING, payload:long::STRING, payload:lon::STRING, payload:x::STRING)) AS lon
  FROM BRONZE.RAW_BOSTON_FOOD_LICENSES
)
SELECT f.*,
       IFF(f.description ILIKE '%retail%', '4451', '7225') AS naics_code,
       n.neighborhood_name
FROM f
LEFT JOIN NEIGHBORHOODS n
  ON f.lat BETWEEN 42.2 AND 42.5 AND ST_CONTAINS(n.geog, ST_MAKEPOINT(f.lon, f.lat))
QUALIFY ROW_NUMBER() OVER (PARTITION BY f.establishment_id ORDER BY n.neighborhood_name) = 1;

-- ---------------------------------------------------------------------
-- D. CHECKS (the last result shown after Run All)
-- ---------------------------------------------------------------------
SELECT 'RULES' AS silver_table, COUNT(*) AS row_count, NULL AS note FROM RULES
UNION ALL SELECT 'RULE_AGENCIES', COUNT(*), NULL FROM RULE_AGENCIES
UNION ALL SELECT 'RULE_CFR_PARTS', (SELECT COUNT(*) FROM RULE_CFR_PARTS),
  (SELECT COUNT(*) FROM BRONZE.RAW_FEDERAL_REGISTER r, LATERAL FLATTEN(input => r.payload:cfr_references) c
   WHERE c.value:part::STRING IS NULL OR c.value:title::STRING IS NULL) || ' references without a part excluded'
UNION ALL SELECT 'RULE_DOCKETS', COUNT(*), NULL FROM RULE_DOCKETS
UNION ALL SELECT 'RULE_RINS', COUNT(*), COUNT_IF(NOT is_valid_format) || ' RINs with unusual format' FROM RULE_RINS
UNION ALL SELECT 'REGS_GOV_DOCUMENTS', COUNT(*), COUNT_IF(open_for_comment) || ' open for comment' FROM REGS_GOV_DOCUMENTS
UNION ALL SELECT 'AGENCIES', COUNT(*), COUNT(agency_acronym) || ' with an acronym' FROM AGENCIES
UNION ALL SELECT 'ID_CROSSWALK', COUNT(*), ROUND(100 * COUNT_IF(matched_to_regs_gov) / COUNT(*), 1) || '% matched to Regulations.gov' FROM ID_CROSSWALK
UNION ALL SELECT 'CFR_VERSIONS', COUNT(*), NULL FROM CFR_VERSIONS
UNION ALL SELECT 'CFR_PART_TEXT', COUNT(*), NULL FROM CFR_PART_TEXT
UNION ALL SELECT 'BILLS', COUNT(*), COUNT_IF(is_small_business_relevant) || ' small-business relevant' FROM BILLS
UNION ALL SELECT 'MA_REGULATIONS', COUNT(*), NULL FROM MA_REGULATIONS
UNION ALL SELECT 'NAICS', COUNT(*), COUNT(sector_title) || ' with a sector title' FROM NAICS
UNION ALL SELECT 'NEIGHBORHOODS', COUNT(*), COUNT(geog) || ' with valid boundaries' FROM NEIGHBORHOODS
UNION ALL SELECT 'CENSUS_TRACTS', COUNT(*), COUNT(neighborhood_name) || ' placed in a neighborhood' FROM CENSUS_TRACTS
UNION ALL SELECT 'COLLEGES', COUNT(*), COUNT(neighborhood_name) || ' in a Boston neighborhood' FROM COLLEGES
UNION ALL SELECT 'MBTA_STATIONS', COUNT(*), COUNT(neighborhood_name) || ' in a Boston neighborhood' FROM MBTA_STATIONS
UNION ALL SELECT 'BUSINESS_COUNTS', COUNT(*), NULL FROM BUSINESS_COUNTS
UNION ALL SELECT 'FOOD_ESTABLISHMENTS', COUNT(*), COUNT(neighborhood_name) || ' placed in a neighborhood' FROM FOOD_ESTABLISHMENTS;
