-- =====================================================================
-- RegRadar | 07_demo_walkthrough.sql
-- The queries to run live in the demo, in presentation order.
-- Click inside one query and press ▶ (Ctrl + Enter) to run just that query.
-- =====================================================================
USE WAREHOUSE REGRADAR_WH;
USE DATABASE REGRADAR_DB;

-- =====================================================================
-- PART 1. ACTUAL DATA (bronze)
-- =====================================================================

-- 1.1 Every source, loaded: 13 tables, 69,355 rows
SELECT table_name, row_count, ROUND(bytes / 1024 / 1024, 1) AS size_mb
FROM INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'BRONZE'
ORDER BY row_count DESC;

-- 1.2 One record exactly as the Federal Register API sent it, with where and when it was loaded
SELECT payload, source_file, loaded_at
FROM BRONZE.RAW_FEDERAL_REGISTER
ORDER BY payload:publication_date::DATE DESC
LIMIT 1;

-- =====================================================================
-- PART 2. CLEANING AND LINKING (silver)
-- =====================================================================

-- 2.1 The same data, cleaned: real dates, counts, no duplicates
SELECT document_number, document_type, title, publication_date, effective_date,
       agency_count, docket_count, cfr_reference_count, is_significant
FROM SILVER.RULES
ORDER BY publication_date DESC
LIMIT 10;

-- 2.2 The ID crosswalk: one rule, every identifier it has across sources
SELECT document_number, document_type, publication_date,
       rins, docket_ids, cfr_citations, regs_gov_ids, comment_end_date
FROM SILVER.ID_CROSSWALK
WHERE matched_to_regs_gov AND ARRAY_SIZE(rins) > 0 AND ARRAY_SIZE(cfr_citations) > 0
ORDER BY publication_date DESC
LIMIT 5;

-- 2.3 Do the sources connect? 93.4% of Regulations.gov documents match a Federal Register rule
SELECT COUNT(*)                                          AS regs_gov_documents,
       COUNT(r.document_number)                          AS matched,
       ROUND(100 * matched / regs_gov_documents, 1)      AS match_pct
FROM SILVER.REGS_GOV_DOCUMENTS g
LEFT JOIN SILVER.RULES r ON r.document_number = g.fr_doc_num;

-- =====================================================================
-- PART 3. THE DATA MODEL (gold star schema)
-- =====================================================================

-- 3.1 The model: 6 facts, 10 dimensions, 4 bridges, all loaded
SELECT table_name, row_count,
       CASE WHEN table_name LIKE 'FACT%' THEN 'Fact'
            WHEN table_name LIKE 'DIM%' THEN 'Dimension' ELSE 'Bridge' END AS table_type
FROM INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'GOLD'
ORDER BY table_type, table_name;

-- 3.2 Star query: rules affecting restaurants and cafes (NAICS 722), by year and agency
SELECT d.year, a.agency_name, COUNT(DISTINCT f.rule_key) AS rules
FROM GOLD.FACT_RULE f
JOIN GOLD.DIM_DATE d              ON d.date_key = f.publication_date_key
JOIN GOLD.DIM_AGENCY a            ON a.agency_key = f.primary_agency_key
JOIN GOLD.BRIDGE_RULE_INDUSTRY bi ON bi.rule_key = f.rule_key
JOIN GOLD.DIM_INDUSTRY i          ON i.industry_key = bi.industry_key
WHERE i.naics_code = '722'
GROUP BY d.year, a.agency_name
ORDER BY d.year DESC, rules DESC;

-- 3.3 What can a small business still comment on? Open proposed rules for the 3 demo industries
SELECT i.naics_title                                   AS industry,
       r.title,
       a.agency_name,
       ce.full_date                                    AS comment_deadline,
       DATEDIFF(day, CURRENT_DATE(), ce.full_date)     AS days_left,
       r.html_url
FROM GOLD.FACT_RULE f
JOIN GOLD.DIM_RULE r              ON r.rule_key = f.rule_key
JOIN GOLD.DIM_AGENCY a            ON a.agency_key = f.primary_agency_key
JOIN GOLD.DIM_DATE ce             ON ce.date_key = f.comment_end_date_key
JOIN GOLD.BRIDGE_RULE_INDUSTRY bi ON bi.rule_key = f.rule_key
JOIN GOLD.DIM_INDUSTRY i          ON i.industry_key = bi.industry_key
WHERE i.naics_code IN ('722', '23', '44-45')
  AND ce.full_date >= CURRENT_DATE()
ORDER BY ce.full_date
LIMIT 20;

-- 3.4 How often do construction safety rules change? (transaction fact)
SELECT d.year,
       COUNT(*)                     AS section_changes,
       COUNT_IF(f.is_substantive)   AS substantive_changes
FROM GOLD.FACT_CFR_CHANGE f
JOIN GOLD.DIM_CFR_PART p ON p.cfr_part_key = f.cfr_part_key
JOIN GOLD.DIM_DATE d     ON d.date_key = f.change_date_key
WHERE p.cfr_citation = '29 CFR 1926' AND d.year IS NOT NULL
GROUP BY d.year
ORDER BY d.year;

-- 3.5 SCD Type 2: which version of the FDA food safety rule was in force on March 1, 2025?
SELECT cfr_citation, part_name, valid_from, valid_to, is_current
FROM GOLD.DIM_CFR_PART
WHERE cfr_citation = '21 CFR 117'
  AND '2025-03-01'::DATE BETWEEN valid_from AND valid_to;

-- 3.6 Versions kept per CFR part (the history behind "as of" questions)
SELECT cfr_citation, part_name, COUNT(*) AS versions,
       MIN(valid_from) AS first_version, MAX(valid_from) AS latest_version
FROM GOLD.DIM_CFR_PART
WHERE part_name IS NOT NULL
GROUP BY cfr_citation, part_name
ORDER BY versions DESC;

-- =====================================================================
-- PART 4. LOCATION ADVISOR (location star)
-- =====================================================================

-- 4.1 Fenway vs. Jamaica Plain for a cafe
SELECT n.neighborhood_name,
       p.residents,
       ROUND(100 * p.residents_18_34 / NULLIF(p.residents, 0)) AS pct_18_34,
       p.college_count, p.students_nearby,
       p.transit_station_count, p.transit_line_count,
       p.food_establishment_count,
       ROUND((p.residents + p.students_nearby) / NULLIF(p.food_establishment_count, 0)) AS people_per_food_place
FROM GOLD.FACT_NEIGHBORHOOD_PROFILE p
JOIN GOLD.DIM_NEIGHBORHOOD n ON n.neighborhood_key = p.neighborhood_key
WHERE n.neighborhood_name IN ('Fenway', 'Jamaica Plain');

-- 4.2 All 26 neighborhoods ranked by people per food place (less crowded markets first)
SELECT n.neighborhood_name, p.residents, p.students_nearby, p.food_establishment_count,
       ROUND((p.residents + p.students_nearby) / NULLIF(p.food_establishment_count, 0)) AS people_per_food_place
FROM GOLD.FACT_NEIGHBORHOOD_PROFILE p
JOIN GOLD.DIM_NEIGHBORHOOD n ON n.neighborhood_key = p.neighborhood_key
WHERE p.food_establishment_count >= 10
ORDER BY people_per_food_place DESC;

-- 4.3 Same neighborhoods, opposite answer: cafes vs. construction businesses by ZIP (Census)
SELECT z.zip_code, z.primary_neighborhood_name, i.naics_title AS industry, b.establishments
FROM GOLD.FACT_BUSINESS_COUNT b
JOIN GOLD.DIM_ZIP z      ON z.zip_key = b.zip_key
JOIN GOLD.DIM_INDUSTRY i ON i.industry_key = b.industry_key
WHERE z.zip_code IN ('02115', '02215', '02130')
  AND i.naics_code IN ('722515', '23')
ORDER BY i.naics_code, z.zip_code;

-- =====================================================================
-- PART 5. HOW THE TWO STARS CONNECT (conformed DIM_INDUSTRY)
-- =====================================================================

-- 5.1 One industry code answers both questions: "which rules?" and "how much competition?"
SELECT 'Rules affecting food service (sector 72) published this year' AS metric,
       COUNT(DISTINCT f.rule_key) AS value
FROM GOLD.FACT_RULE f
JOIN GOLD.DIM_DATE d              ON d.date_key = f.publication_date_key
JOIN GOLD.BRIDGE_RULE_INDUSTRY bi ON bi.rule_key = f.rule_key
JOIN GOLD.DIM_INDUSTRY i          ON i.industry_key = bi.industry_key
WHERE i.sector_code = '72' AND d.year = YEAR(CURRENT_DATE())
UNION ALL
SELECT 'Food service establishments in Fenway (sector 72)',
       COUNT(*)
FROM GOLD.FACT_ESTABLISHMENT e
JOIN GOLD.DIM_INDUSTRY i     ON i.industry_key = e.industry_key
JOIN GOLD.DIM_NEIGHBORHOOD n ON n.neighborhood_key = e.neighborhood_key
WHERE i.sector_code = '72' AND n.neighborhood_name = 'Fenway';

-- =====================================================================
-- PART 6. DATA QUALITY: run 06_data_quality_checks.sql for the full PASS/FAIL checklist
-- =====================================================================
