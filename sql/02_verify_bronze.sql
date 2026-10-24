-- =====================================================================
-- RegRadar | 02_verify_bronze.sql
-- Checks the bronze layer after loading. Run each query on its own (▶)
-- to see its result.
-- =====================================================================
USE WAREHOUSE REGRADAR_WH;
USE SCHEMA REGRADAR_DB.BRONZE;

-- 1. Every bronze table, its rows and size (expect 13 tables, 69,355 rows)
SELECT table_name, row_count, ROUND(bytes / 1024 / 1024, 1) AS size_mb, last_altered
FROM REGRADAR_DB.INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'BRONZE'
ORDER BY row_count DESC;

-- 2. Every table uses the same raw column (expect 13 rows, all PAYLOAD)
SELECT table_name, column_name
FROM REGRADAR_DB.INFORMATION_SCHEMA.COLUMNS
WHERE table_schema = 'BRONZE' AND data_type = 'VARIANT'
ORDER BY table_name;

-- 3. Peek inside the raw JSON of the Federal Register
SELECT
  PAYLOAD:document_number::STRING   AS document_number,
  PAYLOAD:type::STRING              AS doc_type,
  PAYLOAD:title::STRING             AS title,
  PAYLOAD:publication_date::DATE    AS published,
  PAYLOAD:effective_on::DATE        AS effective_on,
  PAYLOAD:regulation_id_numbers     AS rins,
  PAYLOAD:docket_ids                AS docket_ids,
  PAYLOAD:cfr_references            AS cfr_refs,
  SOURCE_FILE,
  LOADED_AT
FROM RAW_FEDERAL_REGISTER
ORDER BY published DESC
LIMIT 20;

-- 4. Rules per agency and type (click Chart for a bar chart)
SELECT
  a.value:name::STRING  AS agency,
  PAYLOAD:type::STRING  AS doc_type,
  COUNT(*)              AS docs
FROM RAW_FEDERAL_REGISTER,
     LATERAL FLATTEN(input => PAYLOAD:agencies) a
GROUP BY 1, 2
ORDER BY docs DESC
LIMIT 25;

-- 5. Which IDs can we link sources on? (RIN 63.6%, docket 89.2%, CFR 99.9%)
SELECT
  COUNT(*)                                                 AS total_rules,
  COUNT_IF(ARRAY_SIZE(PAYLOAD:regulation_id_numbers) > 0)  AS with_rin,
  COUNT_IF(ARRAY_SIZE(PAYLOAD:docket_ids) > 0)             AS with_docket,
  COUNT_IF(ARRAY_SIZE(PAYLOAD:cfr_references) > 0)         AS with_cfr,
  ROUND(100 * with_rin / total_rules, 1)                   AS pct_rin,
  ROUND(100 * with_docket / total_rules, 1)                AS pct_docket,
  ROUND(100 * with_cfr / total_rules, 1)                   AS pct_cfr
FROM RAW_FEDERAL_REGISTER;

-- 6. Do the sources connect? Regulations.gov -> Federal Register (expect about 93%)
SELECT
  COUNT(*)                                        AS regs_gov_documents,
  COUNT(fr.PAYLOAD:document_number)               AS matched_to_federal_register,
  ROUND(100 * matched_to_federal_register / regs_gov_documents, 1) AS match_pct
FROM RAW_REGULATIONS_GOV rg
LEFT JOIN RAW_FEDERAL_REGISTER fr
  ON fr.PAYLOAD:document_number::STRING = rg.PAYLOAD:frDocNum::STRING;
