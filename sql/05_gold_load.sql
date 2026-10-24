-- =====================================================================
-- RegRadar | 05_gold_load.sql
-- GOLD layer load
-- Fills the 20 star schema tables (created by 04_gold_schema.sql) from SILVER.
-- Full refresh: every table is emptied and reloaded. Run with Run All.
-- =====================================================================
USE WAREHOUSE REGRADAR_WH;
USE DATABASE REGRADAR_DB;
USE SCHEMA GOLD;

-- Helper: turn a date into a DIM_DATE key (YYYYMMDD), or -1 if missing or out of range
CREATE OR REPLACE FUNCTION DATE_KEY(d DATE)
RETURNS NUMBER
AS $$ IFF(d BETWEEN '1990-01-01'::DATE AND '2035-12-31'::DATE, TO_NUMBER(TO_CHAR(d, 'YYYYMMDD')), -1) $$;

-- 0. Empty everything (facts, bridges, then dimensions)
TRUNCATE TABLE FACT_RULE;               TRUNCATE TABLE FACT_CFR_CHANGE;      TRUNCATE TABLE FACT_BILL;
TRUNCATE TABLE FACT_NEIGHBORHOOD_PROFILE; TRUNCATE TABLE FACT_BUSINESS_COUNT; TRUNCATE TABLE FACT_ESTABLISHMENT;
TRUNCATE TABLE BRIDGE_RULE_AGENCY;      TRUNCATE TABLE BRIDGE_RULE_CFR_PART; TRUNCATE TABLE BRIDGE_RULE_DOCKET;
TRUNCATE TABLE BRIDGE_RULE_INDUSTRY;
TRUNCATE TABLE DIM_DATE;   TRUNCATE TABLE DIM_JURISDICTION; TRUNCATE TABLE DIM_AGENCY; TRUNCATE TABLE DIM_RULE;
TRUNCATE TABLE DIM_DOCKET; TRUNCATE TABLE DIM_CFR_PART;     TRUNCATE TABLE DIM_INDUSTRY; TRUNCATE TABLE DIM_BILL;
TRUNCATE TABLE DIM_NEIGHBORHOOD; TRUNCATE TABLE DIM_ZIP;

-- =====================================================================
-- 1. DIMENSIONS (each gets an "Unknown" member with key -1)
-- =====================================================================

-- DIM_DATE: every day from 1990 to 2035 (eCFR history goes back decades; effective dates go into the future)
INSERT INTO DIM_DATE (DATE_KEY, FULL_DATE, YEAR, QUARTER, MONTH, MONTH_NAME, DAY_OF_MONTH,
                      DAY_OF_WEEK, DAY_NAME, IS_WEEKEND, FEDERAL_FISCAL_YEAR)
SELECT -1, NULL, NULL, NULL, NULL, 'Unknown', NULL, NULL, 'Unknown', NULL, NULL
UNION ALL
SELECT DATE_KEY(d), d, YEAR(d), QUARTER(d), MONTH(d), TO_CHAR(d, 'MMMM'), DAY(d),
       DAYOFWEEKISO(d), DAYNAME(d), DAYOFWEEKISO(d) >= 6,
       IFF(MONTH(d) >= 10, YEAR(d) + 1, YEAR(d))           -- federal fiscal year starts October 1
FROM (SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '1990-01-01'::DATE) AS d
      FROM TABLE(GENERATOR(ROWCOUNT => 17000)))
WHERE d <= '2035-12-31';

INSERT INTO DIM_JURISDICTION VALUES
  (-1, 'UNK', 'Unknown', 'Unknown'),
  ( 1, 'US',  'United States', 'Federal'),
  ( 2, 'MA',  'Massachusetts', 'State');

INSERT INTO DIM_AGENCY (AGENCY_KEY, FR_AGENCY_ID, AGENCY_SLUG, AGENCY_NAME, AGENCY_ACRONYM, PARENT_AGENCY_NAME)
SELECT -1, NULL, 'unknown', 'Unknown agency', NULL, NULL
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY agency_slug), fr_agency_id, LEFT(agency_slug, 200), LEFT(agency_name, 500),
       LEFT(agency_acronym, 20), LEFT(parent_agency_name, 500)
FROM SILVER.AGENCIES;

-- DIM_RULE: federal rules plus Massachusetts regulations
INSERT INTO DIM_RULE (RULE_KEY, DOCUMENT_NUMBER, TITLE, DOCUMENT_TYPE, ACTION, ABSTRACT, PRIMARY_RIN,
                      IS_SIGNIFICANT, HTML_URL, SOURCE_SYSTEM)
SELECT -1, 'UNKNOWN', 'Unknown rule', 'Unknown', NULL, NULL, NULL, NULL, NULL, NULL
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY source_system, document_number), document_number, title, document_type,
       action, abstract, primary_rin, is_significant, html_url, source_system
FROM (
  SELECT LEFT(document_number, 50) AS document_number, LEFT(title, 2000) AS title,
         LEFT(document_type, 30) AS document_type, LEFT(action, 500) AS action,
         LEFT(abstract, 16000) AS abstract, LEFT(primary_rin, 20) AS primary_rin,
         is_significant, LEFT(html_url, 1000) AS html_url, 'Federal Register' AS source_system
  FROM SILVER.RULES
  UNION ALL
  SELECT citation,
         CASE citation
           WHEN '105 CMR 590' THEN 'State sanitary code: minimum sanitation standards for food establishments'
           WHEN '454 CMR 27'  THEN 'Minimum wage regulations'
           WHEN '940 CMR 33'  THEN 'Earned sick time'
           ELSE citation END,
         'State Regulation', NULL, NULL, NULL, FALSE, NULL, 'mass.gov'
  FROM SILVER.MA_REGULATIONS
);

INSERT INTO DIM_DOCKET (DOCKET_KEY, DOCKET_ID, AGENCY_ACRONYM)
SELECT -1, 'UNKNOWN', NULL
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY docket_id), docket_id,
       REGEXP_SUBSTR(docket_id, '^([A-Z]{2,})-', 1, 1, 'e', 1)
FROM (SELECT DISTINCT LEFT(docket_id, 100) AS docket_id FROM SILVER.RULE_DOCKETS WHERE docket_id IS NOT NULL
      UNION
      SELECT DISTINCT LEFT(docket_id, 100) FROM SILVER.REGS_GOV_DOCUMENTS WHERE docket_id IS NOT NULL);

-- DIM_CFR_PART (SCD Type 2): one row per version for the 6 parts with eCFR history,
-- one always-current row for every other part that rules reference
INSERT INTO DIM_CFR_PART (CFR_PART_KEY, CFR_TITLE, CFR_PART, CFR_CITATION, PART_NAME, VALID_FROM, VALID_TO, IS_CURRENT)
WITH v AS (
  SELECT DISTINCT cfr_title, LEFT(cfr_part, 20) AS cfr_part, LEFT(cfr_citation, 30) AS cfr_citation,
         version_date AS valid_from
  FROM SILVER.CFR_VERSIONS WHERE version_date IS NOT NULL
),
versioned AS (
  SELECT cfr_title, cfr_part, cfr_citation,
         CASE cfr_citation
           WHEN '21 CFR 117'  THEN 'Current good manufacturing practice and preventive controls for human food'
           WHEN '21 CFR 101'  THEN 'Food labeling'
           WHEN '29 CFR 1910' THEN 'Occupational safety and health standards'
           WHEN '29 CFR 1926' THEN 'Safety and health regulations for construction'
           WHEN '29 CFR 516'  THEN 'Records to be kept by employers'
           WHEN '40 CFR 82'   THEN 'Protection of stratospheric ozone'
         END AS part_name,
         valid_from,
         COALESCE(DATEADD(day, -1, LEAD(valid_from) OVER (PARTITION BY cfr_citation ORDER BY valid_from)),
                  '9999-12-31'::DATE) AS valid_to,
         LEAD(valid_from) OVER (PARTITION BY cfr_citation ORDER BY valid_from) IS NULL AS is_current
  FROM v
),
unversioned AS (
  SELECT DISTINCT rc.cfr_title, LEFT(rc.cfr_part, 20) AS cfr_part, LEFT(rc.cfr_citation, 30) AS cfr_citation,
         NULL AS part_name, '1900-01-01'::DATE AS valid_from, '9999-12-31'::DATE AS valid_to, TRUE AS is_current
  FROM SILVER.RULE_CFR_PARTS rc
  WHERE LEFT(rc.cfr_citation, 30) NOT IN (SELECT cfr_citation FROM v)
),
all_parts AS (
  SELECT * FROM versioned
  UNION ALL
  SELECT * FROM unversioned
)
SELECT -1, NULL, NULL, 'Unknown', NULL, NULL, NULL, NULL
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY cfr_title, cfr_part, valid_from), cfr_title, cfr_part, cfr_citation,
       part_name, valid_from, valid_to, is_current
FROM all_parts;

INSERT INTO DIM_INDUSTRY (INDUSTRY_KEY, NAICS_CODE, NAICS_TITLE, NAICS_LEVEL, SECTOR_CODE, SECTOR_TITLE,
                          SUBSECTOR_CODE, INDUSTRY_GROUP_CODE, DEMO_INDUSTRY, NAICS_VERSION)
SELECT -1, 'UNKNOWN', 'Unknown industry', NULL, NULL, NULL, NULL, NULL, NULL, NULL
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY naics_code), naics_code, LEFT(naics_title, 500), naics_level, sector_code,
       LEFT(sector_title, 500), subsector_code, industry_group_code, demo_industry, naics_version
FROM SILVER.NAICS;

INSERT INTO DIM_BILL (BILL_KEY, BILL_ID, SESSION_NAME, BILL_TYPE, BILL_NUMBER, TITLE, ORIGIN_CHAMBER,
                      LATEST_ACTION_TEXT, BILL_URL)
SELECT -1, 'UNKNOWN', NULL, NULL, NULL, 'Unknown bill', NULL, NULL, NULL
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY bill_id), LEFT(bill_id, 50), congress || 'th Congress', LEFT(bill_type, 10),
       LEFT(bill_number, 20), LEFT(title, 4000), LEFT(origin_chamber, 20), LEFT(latest_action_text, 4000),
       LEFT(bill_url, 1000)
FROM SILVER.BILLS;

INSERT INTO DIM_NEIGHBORHOOD (NEIGHBORHOOD_KEY, NEIGHBORHOOD_NAME, CITY, AREA_SQ_MILES, CENTROID_LAT, CENTROID_LON)
SELECT -1, 'Outside Boston / unknown', NULL, NULL, NULL, NULL
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY neighborhood_name), LEFT(neighborhood_name, 100), 'Boston',
       area_sq_miles, centroid_lat, centroid_lon
FROM SILVER.NEIGHBORHOODS;

-- DIM_ZIP: primary neighborhood = the neighborhood where most of that ZIP's food establishments sit
INSERT INTO DIM_ZIP (ZIP_KEY, ZIP_CODE, CITY, PRIMARY_NEIGHBORHOOD_NAME)
WITH z AS (
  SELECT zip_code FROM SILVER.BUSINESS_COUNTS WHERE zip_code IS NOT NULL
  UNION
  SELECT zip_code FROM SILVER.FOOD_ESTABLISHMENTS WHERE zip_code IS NOT NULL
),
hood AS (SELECT zip_code, MODE(neighborhood_name) AS primary_neighborhood
         FROM SILVER.FOOD_ESTABLISHMENTS GROUP BY zip_code),
city AS (SELECT LPAD(NULLIF(SPLIT_PART(payload:zip::STRING, '.', 1), ''), 5, '0') AS zip_code,
                MODE(payload:city::STRING) AS city
         FROM BRONZE.RAW_BOSTON_FOOD_LICENSES GROUP BY 1)
SELECT -1, '00000', NULL, NULL
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY z.zip_code), z.zip_code, LEFT(city.city, 50), LEFT(hood.primary_neighborhood, 100)
FROM z
LEFT JOIN hood ON hood.zip_code = z.zip_code
LEFT JOIN city ON city.zip_code = z.zip_code;

-- =====================================================================
-- 2. BRIDGES
-- =====================================================================

INSERT INTO BRIDGE_RULE_AGENCY (RULE_KEY, AGENCY_KEY, AGENCY_ORDER)
SELECT r.rule_key, a.agency_key, MIN(ra.agency_order)
FROM SILVER.RULE_AGENCIES ra
JOIN DIM_RULE r   ON r.document_number = ra.document_number AND r.source_system = 'Federal Register'
JOIN DIM_AGENCY a ON a.agency_slug = LEFT(ra.agency_slug, 200)
GROUP BY r.rule_key, a.agency_key;

INSERT INTO BRIDGE_RULE_DOCKET (RULE_KEY, DOCKET_KEY)
SELECT DISTINCT r.rule_key, d.docket_key
FROM SILVER.RULE_DOCKETS rd
JOIN DIM_RULE r   ON r.document_number = rd.document_number AND r.source_system = 'Federal Register'
JOIN DIM_DOCKET d ON d.docket_id = LEFT(rd.docket_id, 100);

-- Link each rule to the CFR part VERSION in force on its publication date (the Type 2 lookup)
INSERT INTO BRIDGE_RULE_CFR_PART (RULE_KEY, CFR_PART_KEY)
SELECT rule_key, cfr_part_key FROM (
  SELECT r.rule_key, d.cfr_part_key
  FROM SILVER.RULE_CFR_PARTS rc
  JOIN SILVER.RULES s     ON s.document_number = rc.document_number
  JOIN DIM_RULE r         ON r.document_number = rc.document_number AND r.source_system = 'Federal Register'
  JOIN DIM_CFR_PART d     ON d.cfr_citation = LEFT(rc.cfr_citation, 30)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY r.rule_key, rc.cfr_citation
    ORDER BY IFF(s.publication_date BETWEEN d.valid_from AND d.valid_to, 0, 1), d.is_current DESC) = 1
);

-- Baseline industry tagging (before Cortex): precise CFR-part rules plus simple keywords.
-- Cortex tagging will add to this table later with TAG_METHOD = 'cortex'.
INSERT INTO BRIDGE_RULE_INDUSTRY (RULE_KEY, INDUSTRY_KEY, RELEVANCE_SCORE, TAG_METHOD, TAGGED_AT)
WITH cfr_map (cfr_citation, naics_code, score) AS (
  SELECT * FROM VALUES
    ('21 CFR 117', '722', 0.9), ('21 CFR 101', '722', 0.8), ('21 CFR 101', '44-45', 0.8),
    ('29 CFR 1926', '23', 0.95), ('29 CFR 1910', '722', 0.7), ('29 CFR 1910', '44-45', 0.7),
    ('29 CFR 1910', '23', 0.7),  ('29 CFR 516', '722', 0.8),  ('29 CFR 516', '44-45', 0.8),
    ('29 CFR 516', '23', 0.8),   ('40 CFR 82', '722', 0.6),   ('40 CFR 82', '44-45', 0.6)
),
keyword_map (pattern, naics_code, score) AS (
  SELECT * FROM VALUES
    ('restaurant', '722', 0.6), ('food service', '722', 0.6), ('food establishment', '722', 0.6),
    ('construction', '23', 0.5), ('contractor', '23', 0.5),
    ('retail', '44-45', 0.5), ('grocery', '44-45', 0.5)
),
tags AS (
  SELECT rc.document_number, m.naics_code, m.score, 'cfr_part' AS method
  FROM SILVER.RULE_CFR_PARTS rc JOIN cfr_map m ON m.cfr_citation = rc.cfr_citation
  UNION ALL
  SELECT s.document_number, k.naics_code, k.score, 'keyword'
  FROM SILVER.RULES s
  JOIN keyword_map k ON CONTAINS(LOWER(COALESCE(s.title, '') || ' ' || COALESCE(s.abstract, '')), k.pattern)
)
SELECT r.rule_key, i.industry_key, MAX(t.score), MAX_BY(t.method, t.score), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM tags t
JOIN DIM_RULE r     ON r.document_number = t.document_number AND r.source_system = 'Federal Register'
JOIN DIM_INDUSTRY i ON i.naics_code = t.naics_code
GROUP BY r.rule_key, i.industry_key;

-- =====================================================================
-- 3. FACTS
-- =====================================================================

-- FACT_RULE (accumulating snapshot): one row per rule with its milestone dates
INSERT INTO FACT_RULE (RULE_KEY, PRIMARY_AGENCY_KEY, JURISDICTION_KEY, PUBLICATION_DATE_KEY, EFFECTIVE_DATE_KEY,
                       COMMENT_START_DATE_KEY, COMMENT_END_DATE_KEY, DAYS_PUBLICATION_TO_EFFECTIVE,
                       COMMENT_PERIOD_DAYS, AGENCY_COUNT, CFR_PART_COUNT, DOCKET_COUNT, HAS_RIN,
                       IS_OPEN_FOR_COMMENT, MATCHED_TO_REGULATIONS_GOV, RULE_COUNT)
SELECT r.rule_key,
       COALESCE(pa.agency_key, -1),
       1,
       DATE_KEY(s.publication_date),
       DATE_KEY(s.effective_date),
       DATE_KEY(cw.comment_start_date),
       DATE_KEY(COALESCE(cw.comment_end_date, s.comments_close_date)),
       DATEDIFF(day, s.publication_date, s.effective_date),
       DATEDIFF(day, COALESCE(cw.comment_start_date, s.publication_date),
                     COALESCE(cw.comment_end_date, s.comments_close_date)),
       s.agency_count, s.cfr_reference_count, s.docket_count, s.rin_count > 0,
       COALESCE(cw.open_for_comment, FALSE)
         OR COALESCE(COALESCE(cw.comment_end_date, s.comments_close_date) >= CURRENT_DATE(), FALSE),
       COALESCE(cw.matched_to_regs_gov, FALSE),
       1
FROM SILVER.RULES s
JOIN DIM_RULE r ON r.document_number = s.document_number AND r.source_system = 'Federal Register'
LEFT JOIN SILVER.ID_CROSSWALK cw ON cw.document_number = s.document_number
LEFT JOIN (SELECT ra.document_number, a.agency_key
           FROM SILVER.RULE_AGENCIES ra
           JOIN DIM_AGENCY a ON a.agency_slug = LEFT(ra.agency_slug, 200)
           WHERE ra.agency_order = 1) pa ON pa.document_number = s.document_number
UNION ALL
SELECT r.rule_key, -1, 2, -1, -1, -1, -1, NULL, NULL, 0, 0, 0, FALSE, FALSE, FALSE, 1
FROM DIM_RULE r WHERE r.source_system = 'mass.gov';

-- FACT_CFR_CHANGE (transaction): one row per section version, linked to the part version it created
INSERT INTO FACT_CFR_CHANGE (CFR_CHANGE_ID, CFR_PART_KEY, JURISDICTION_KEY, CHANGE_DATE_KEY, AMENDMENT_DATE_KEY,
                             SECTION_IDENTIFIER, IS_SUBSTANTIVE, IS_REMOVED, CHANGE_COUNT)
SELECT ROW_NUMBER() OVER (ORDER BY v.cfr_citation, v.version_date, v.section_identifier),
       COALESCE(d.cfr_part_key, -1), 1,
       DATE_KEY(v.version_date), DATE_KEY(v.amendment_date),
       LEFT(v.section_identifier, 50), v.is_substantive, v.is_removed, 1
FROM SILVER.CFR_VERSIONS v
LEFT JOIN DIM_CFR_PART d ON d.cfr_citation = LEFT(v.cfr_citation, 30) AND d.valid_from = v.version_date;

INSERT INTO FACT_BILL (BILL_KEY, JURISDICTION_KEY, LATEST_ACTION_DATE_KEY, UPDATE_DATE_KEY,
                       IS_SMALL_BUSINESS_RELEVANT, BILL_COUNT)
SELECT d.bill_key, 1, DATE_KEY(b.latest_action_date), DATE_KEY(b.update_date), b.is_small_business_relevant, 1
FROM SILVER.BILLS b
JOIN DIM_BILL d ON d.bill_id = LEFT(b.bill_id, 50);

-- FACT_NEIGHBORHOOD_PROFILE (periodic snapshot): one row per neighborhood for today's snapshot
INSERT INTO FACT_NEIGHBORHOOD_PROFILE (NEIGHBORHOOD_KEY, SNAPSHOT_DATE_KEY, ACS_YEAR, RESIDENTS, RESIDENTS_18_34,
                                       MEDIAN_HOUSEHOLD_INCOME, COLLEGE_COUNT, STUDENTS_NEARBY,
                                       TRANSIT_STATION_COUNT, TRANSIT_LINE_COUNT, FOOD_ESTABLISHMENT_COUNT)
WITH res AS (SELECT neighborhood_name, SUM(population) AS residents, SUM(age_18_34) AS age_18_34,
                    MEDIAN(median_income) AS median_income
             FROM SILVER.CENSUS_TRACTS GROUP BY 1),
     col AS (SELECT neighborhood_name, COUNT(*) AS colleges, SUM(total_students) AS students
             FROM SILVER.COLLEGES GROUP BY 1),
     sta AS (SELECT s.neighborhood_name, COUNT(DISTINCT s.station_id) AS stations,
                    COUNT(DISTINCT l.value::STRING) AS lines
             FROM SILVER.MBTA_STATIONS s, LATERAL FLATTEN(input => s.lines) l GROUP BY 1),
     food AS (SELECT neighborhood_name, COUNT(*) AS food_places FROM SILVER.FOOD_ESTABLISHMENTS GROUP BY 1),
     acs AS (SELECT MAX(TRY_TO_NUMBER(REGEXP_SUBSTR(source_file, 'suffolk_([0-9]{4})_', 1, 1, 'e', 1))) AS acs_year
             FROM BRONZE.RAW_CENSUS_ACS)
SELECT n.neighborhood_key, DATE_KEY(CURRENT_DATE()), acs.acs_year,
       COALESCE(res.residents, 0), COALESCE(res.age_18_34, 0), res.median_income,
       COALESCE(col.colleges, 0), COALESCE(col.students, 0),
       COALESCE(sta.stations, 0), COALESCE(sta.lines, 0), COALESCE(food.food_places, 0)
FROM DIM_NEIGHBORHOOD n
CROSS JOIN acs
LEFT JOIN res  ON res.neighborhood_name  = n.neighborhood_name
LEFT JOIN col  ON col.neighborhood_name  = n.neighborhood_name
LEFT JOIN sta  ON sta.neighborhood_name  = n.neighborhood_name
LEFT JOIN food ON food.neighborhood_name = n.neighborhood_name
WHERE n.neighborhood_key <> -1;

INSERT INTO FACT_BUSINESS_COUNT (ZIP_KEY, INDUSTRY_KEY, YEAR_DATE_KEY, ESTABLISHMENTS)
SELECT z.zip_key, i.industry_key, DATE_KEY(DATE_FROM_PARTS(b.data_year, 1, 1)), SUM(b.establishments)
FROM SILVER.BUSINESS_COUNTS b
JOIN DIM_ZIP z      ON z.zip_code = b.zip_code
JOIN DIM_INDUSTRY i ON i.naics_code = b.naics_code
GROUP BY z.zip_key, i.industry_key, b.data_year;

-- FACT_ESTABLISHMENT (factless): one row per licensed food establishment
INSERT INTO FACT_ESTABLISHMENT (ESTABLISHMENT_ID, NEIGHBORHOOD_KEY, ZIP_KEY, INDUSTRY_KEY, LICENSE_ADDED_DATE_KEY,
                                BUSINESS_NAME, LATITUDE, LONGITUDE, ESTABLISHMENT_COUNT)
SELECT LEFT(f.establishment_id, 50),
       COALESCE(n.neighborhood_key, -1), COALESCE(z.zip_key, -1), COALESCE(i.industry_key, -1),
       DATE_KEY(f.license_added_date), LEFT(f.business_name, 500), f.lat, f.lon, 1
FROM SILVER.FOOD_ESTABLISHMENTS f
LEFT JOIN DIM_NEIGHBORHOOD n ON n.neighborhood_name = f.neighborhood_name
LEFT JOIN DIM_ZIP z          ON z.zip_code = f.zip_code
LEFT JOIN DIM_INDUSTRY i     ON i.naics_code = f.naics_code;

-- =====================================================================
-- 4. CHECKS (the last result shown after Run All)
-- =====================================================================
SELECT 'DIM_DATE' AS gold_table, COUNT(*) AS row_count FROM DIM_DATE
UNION ALL SELECT 'DIM_JURISDICTION', COUNT(*) FROM DIM_JURISDICTION
UNION ALL SELECT 'DIM_AGENCY', COUNT(*) FROM DIM_AGENCY
UNION ALL SELECT 'DIM_RULE', COUNT(*) FROM DIM_RULE
UNION ALL SELECT 'DIM_DOCKET', COUNT(*) FROM DIM_DOCKET
UNION ALL SELECT 'DIM_CFR_PART', COUNT(*) FROM DIM_CFR_PART
UNION ALL SELECT 'DIM_INDUSTRY', COUNT(*) FROM DIM_INDUSTRY
UNION ALL SELECT 'DIM_BILL', COUNT(*) FROM DIM_BILL
UNION ALL SELECT 'DIM_NEIGHBORHOOD', COUNT(*) FROM DIM_NEIGHBORHOOD
UNION ALL SELECT 'DIM_ZIP', COUNT(*) FROM DIM_ZIP
UNION ALL SELECT 'BRIDGE_RULE_AGENCY', COUNT(*) FROM BRIDGE_RULE_AGENCY
UNION ALL SELECT 'BRIDGE_RULE_CFR_PART', COUNT(*) FROM BRIDGE_RULE_CFR_PART
UNION ALL SELECT 'BRIDGE_RULE_DOCKET', COUNT(*) FROM BRIDGE_RULE_DOCKET
UNION ALL SELECT 'BRIDGE_RULE_INDUSTRY', COUNT(*) FROM BRIDGE_RULE_INDUSTRY
UNION ALL SELECT 'FACT_RULE', COUNT(*) FROM FACT_RULE
UNION ALL SELECT 'FACT_CFR_CHANGE', COUNT(*) FROM FACT_CFR_CHANGE
UNION ALL SELECT 'FACT_BILL', COUNT(*) FROM FACT_BILL
UNION ALL SELECT 'FACT_NEIGHBORHOOD_PROFILE', COUNT(*) FROM FACT_NEIGHBORHOOD_PROFILE
UNION ALL SELECT 'FACT_BUSINESS_COUNT', COUNT(*) FROM FACT_BUSINESS_COUNT
UNION ALL SELECT 'FACT_ESTABLISHMENT', COUNT(*) FROM FACT_ESTABLISHMENT
ORDER BY 1;
