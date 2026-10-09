-- Run after loading. Screenshot these results for this week's slides.
USE ROLE REGRADAR_DEV;
USE WAREHOUSE REGRADAR_WH;
USE SCHEMA REGRADAR_DB.BRONZE;

-- How many records did we load?
SELECT COUNT(*) AS total_docs FROM RAW_FEDERAL_REGISTER;

-- Peek inside the raw JSON
SELECT
  PAYLOAD:document_number::STRING   AS document_number,
  PAYLOAD:type::STRING              AS doc_type,
  PAYLOAD:title::STRING             AS title,
  PAYLOAD:publication_date::DATE    AS published,
  PAYLOAD:effective_on::DATE        AS effective_on,
  PAYLOAD:regulation_id_numbers     AS rins,
  PAYLOAD:docket_ids                AS docket_ids,
  PAYLOAD:cfr_references            AS cfr_refs
FROM RAW_FEDERAL_REGISTER
LIMIT 20;

-- Documents per agency and type (nice chart for the slides)
SELECT
  a.value:name::STRING  AS agency,
  PAYLOAD:type::STRING  AS doc_type,
  COUNT(*)              AS docs
FROM RAW_FEDERAL_REGISTER,
     LATERAL FLATTEN(input => PAYLOAD:agencies) a
GROUP BY 1, 2
ORDER BY docs DESC;

-- Key finding for slides: how many docs have a RIN or docket ID to link on?
SELECT
  COUNT(*)                                                    AS total,
  COUNT_IF(ARRAY_SIZE(PAYLOAD:regulation_id_numbers) > 0)     AS with_rin,
  COUNT_IF(ARRAY_SIZE(PAYLOAD:docket_ids) > 0)                AS with_docket,
  COUNT_IF(ARRAY_SIZE(PAYLOAD:cfr_references) > 0)            AS with_cfr
FROM RAW_FEDERAL_REGISTER;
