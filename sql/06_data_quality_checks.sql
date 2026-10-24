-- =====================================================================
-- RegRadar | 06_data_quality_checks.sql
-- One table of PASS / FAIL / INFO checks across bronze, silver, and gold.
-- Snowflake does not enforce primary or foreign keys, so we test them here.
-- Run with Run All; the result is a single checklist.
-- =====================================================================
USE WAREHOUSE REGRADAR_WH;
USE DATABASE REGRADAR_DB;

WITH checks AS (
  -- ---------- Structure ----------
  SELECT 'Structure' AS area, 'Bronze tables using PAYLOAD' AS check_name,
         (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
          WHERE table_schema = 'BRONZE' AND data_type = 'VARIANT' AND column_name = 'PAYLOAD') AS actual,
         13 AS expected

  -- ---------- Reconciliation: no rows lost between layers ----------
  UNION ALL SELECT 'Reconciliation', 'Bronze rules = silver RULES',
         (SELECT COUNT(DISTINCT payload:document_number::STRING) FROM BRONZE.RAW_FEDERAL_REGISTER),
         (SELECT COUNT(*) FROM SILVER.RULES)
  UNION ALL SELECT 'Reconciliation', 'Silver RULES + MA regulations = gold FACT_RULE',
         (SELECT COUNT(*) FROM GOLD.FACT_RULE),
         (SELECT COUNT(*) FROM SILVER.RULES) + (SELECT COUNT(*) FROM SILVER.MA_REGULATIONS)
  UNION ALL SELECT 'Reconciliation', 'Silver RULE_AGENCIES = gold BRIDGE_RULE_AGENCY',
         (SELECT COUNT(*) FROM GOLD.BRIDGE_RULE_AGENCY), (SELECT COUNT(*) FROM SILVER.RULE_AGENCIES)
  UNION ALL SELECT 'Reconciliation', 'Silver RULE_DOCKETS = gold BRIDGE_RULE_DOCKET',
         (SELECT COUNT(*) FROM GOLD.BRIDGE_RULE_DOCKET), (SELECT COUNT(*) FROM SILVER.RULE_DOCKETS)
  UNION ALL SELECT 'Reconciliation', 'Silver RULE_CFR_PARTS = gold BRIDGE_RULE_CFR_PART',
         (SELECT COUNT(*) FROM GOLD.BRIDGE_RULE_CFR_PART), (SELECT COUNT(*) FROM SILVER.RULE_CFR_PARTS)
  UNION ALL SELECT 'Reconciliation', 'Silver CFR_VERSIONS = gold FACT_CFR_CHANGE',
         (SELECT COUNT(*) FROM GOLD.FACT_CFR_CHANGE), (SELECT COUNT(*) FROM SILVER.CFR_VERSIONS)
  UNION ALL SELECT 'Reconciliation', 'Silver BILLS = gold FACT_BILL',
         (SELECT COUNT(*) FROM GOLD.FACT_BILL), (SELECT COUNT(*) FROM SILVER.BILLS)
  UNION ALL SELECT 'Reconciliation', 'Silver FOOD_ESTABLISHMENTS = gold FACT_ESTABLISHMENT',
         (SELECT COUNT(*) FROM GOLD.FACT_ESTABLISHMENT), (SELECT COUNT(*) FROM SILVER.FOOD_ESTABLISHMENTS)

  -- ---------- Primary keys are unique ----------
  UNION ALL SELECT 'Primary keys', 'Duplicate RULE_KEY in FACT_RULE',
         (SELECT COUNT(*) - COUNT(DISTINCT rule_key) FROM GOLD.FACT_RULE), 0
  UNION ALL SELECT 'Primary keys', 'Duplicate DOCUMENT_NUMBER in DIM_RULE',
         (SELECT COUNT(*) - COUNT(DISTINCT document_number) FROM GOLD.DIM_RULE), 0
  UNION ALL SELECT 'Primary keys', 'Duplicate DATE_KEY in DIM_DATE',
         (SELECT COUNT(*) - COUNT(DISTINCT date_key) FROM GOLD.DIM_DATE), 0
  UNION ALL SELECT 'Primary keys', 'Duplicate ESTABLISHMENT_ID in FACT_ESTABLISHMENT',
         (SELECT COUNT(*) - COUNT(DISTINCT establishment_id) FROM GOLD.FACT_ESTABLISHMENT), 0

  -- ---------- Foreign keys point to real dimension rows ----------
  UNION ALL SELECT 'Foreign keys', 'FACT_RULE -> DIM_RULE orphans',
         (SELECT COUNT(*) FROM GOLD.FACT_RULE f LEFT JOIN GOLD.DIM_RULE d ON d.rule_key = f.rule_key WHERE d.rule_key IS NULL), 0
  UNION ALL SELECT 'Foreign keys', 'FACT_RULE -> DIM_AGENCY orphans',
         (SELECT COUNT(*) FROM GOLD.FACT_RULE f LEFT JOIN GOLD.DIM_AGENCY d ON d.agency_key = f.primary_agency_key WHERE d.agency_key IS NULL), 0
  UNION ALL SELECT 'Foreign keys', 'FACT_RULE -> DIM_DATE orphans (publication)',
         (SELECT COUNT(*) FROM GOLD.FACT_RULE f LEFT JOIN GOLD.DIM_DATE d ON d.date_key = f.publication_date_key WHERE d.date_key IS NULL), 0
  UNION ALL SELECT 'Foreign keys', 'FACT_RULE -> DIM_DATE orphans (effective)',
         (SELECT COUNT(*) FROM GOLD.FACT_RULE f LEFT JOIN GOLD.DIM_DATE d ON d.date_key = f.effective_date_key WHERE d.date_key IS NULL), 0
  UNION ALL SELECT 'Foreign keys', 'BRIDGE_RULE_INDUSTRY -> DIM_INDUSTRY orphans',
         (SELECT COUNT(*) FROM GOLD.BRIDGE_RULE_INDUSTRY b LEFT JOIN GOLD.DIM_INDUSTRY d ON d.industry_key = b.industry_key WHERE d.industry_key IS NULL), 0
  UNION ALL SELECT 'Foreign keys', 'FACT_CFR_CHANGE -> DIM_CFR_PART orphans',
         (SELECT COUNT(*) FROM GOLD.FACT_CFR_CHANGE f LEFT JOIN GOLD.DIM_CFR_PART d ON d.cfr_part_key = f.cfr_part_key WHERE d.cfr_part_key IS NULL), 0
  UNION ALL SELECT 'Foreign keys', 'FACT_ESTABLISHMENT -> DIM_NEIGHBORHOOD orphans',
         (SELECT COUNT(*) FROM GOLD.FACT_ESTABLISHMENT f LEFT JOIN GOLD.DIM_NEIGHBORHOOD d ON d.neighborhood_key = f.neighborhood_key WHERE d.neighborhood_key IS NULL), 0

  -- ---------- Type 2 history is valid ----------
  UNION ALL SELECT 'SCD Type 2', 'CFR parts with more than one current version',
         (SELECT COUNT(*) FROM (SELECT cfr_citation FROM GOLD.DIM_CFR_PART WHERE is_current
                                GROUP BY cfr_citation HAVING COUNT(*) > 1)), 0
  UNION ALL SELECT 'SCD Type 2', 'CFR versions with valid_to before valid_from',
         (SELECT COUNT(*) FROM GOLD.DIM_CFR_PART WHERE valid_to < valid_from), 0

  -- ---------- Source data findings (informational) ----------
  UNION ALL SELECT 'Source findings', 'Malformed RINs (e.g. OMB numbers entered as RINs)',
         (SELECT COUNT_IF(NOT is_valid_format) FROM SILVER.RULE_RINS), NULL
  UNION ALL SELECT 'Source findings', 'CFR references to a whole title/chapter (no part)',
         (SELECT COUNT(*) FROM BRONZE.RAW_FEDERAL_REGISTER r, LATERAL FLATTEN(input => r.payload:cfr_references) c
          WHERE c.value:part::STRING IS NULL OR c.value:title::STRING IS NULL), NULL
  UNION ALL SELECT 'Source findings', 'Regulations.gov docs matched to a Federal Register rule (%)',
         (SELECT ROUND(100 * COUNT(r.document_number) / COUNT(*), 1)
          FROM SILVER.REGS_GOV_DOCUMENTS g LEFT JOIN SILVER.RULES r ON r.document_number = g.fr_doc_num), NULL
  UNION ALL SELECT 'Source findings', 'Federal Register rules matched to Regulations.gov (%)',
         (SELECT ROUND(100 * COUNT_IF(matched_to_regs_gov) / COUNT(*), 1) FROM SILVER.ID_CROSSWALK), NULL
  UNION ALL SELECT 'Source findings', 'Food establishments outside Boston neighborhoods',
         (SELECT COUNT_IF(neighborhood_name IS NULL) FROM SILVER.FOOD_ESTABLISHMENTS), NULL
  UNION ALL SELECT 'Source findings', 'Rules with an effective date before publication',
         (SELECT COUNT_IF(effective_date < publication_date) FROM SILVER.RULES), NULL
)
SELECT area, check_name, actual, expected,
       CASE WHEN expected IS NULL THEN 'INFO'
            WHEN actual = expected THEN 'PASS'
            ELSE 'FAIL' END AS status
FROM checks
ORDER BY CASE area WHEN 'Structure' THEN 1 WHEN 'Reconciliation' THEN 2 WHEN 'Primary keys' THEN 3
                   WHEN 'Foreign keys' THEN 4 WHEN 'SCD Type 2' THEN 5 ELSE 6 END, check_name;
