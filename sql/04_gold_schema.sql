-- =====================================================================
-- RegRadar | 04_gold_schema.sql
-- GOLD layer: Kimball star schema (fact constellation)
-- Creates EMPTY tables with primary and foreign keys.
-- Snowflake stores PK/FK as informational constraints (not enforced),
-- which is exactly what Navicat needs to draw the relationships.
-- Run once in Snowsight with Run All. Safe to re-run (tables are empty).
-- =====================================================================
USE WAREHOUSE REGRADAR_WH;
USE SCHEMA REGRADAR_DB.GOLD;

-- ---------------------------------------------------------------------
-- DIMENSIONS
-- ---------------------------------------------------------------------

-- One row per calendar day. DATE_KEY = YYYYMMDD; -1 = "Unknown date".
CREATE OR REPLACE TABLE DIM_DATE (
  DATE_KEY             NUMBER(8)    NOT NULL,
  FULL_DATE            DATE,
  YEAR                 NUMBER(4),
  QUARTER              NUMBER(1),
  MONTH                NUMBER(2),
  MONTH_NAME           VARCHAR(10),
  DAY_OF_MONTH         NUMBER(2),
  DAY_OF_WEEK          NUMBER(1),
  DAY_NAME             VARCHAR(10),
  IS_WEEKEND           BOOLEAN,
  FEDERAL_FISCAL_YEAR  NUMBER(4),
  CONSTRAINT PK_DIM_DATE PRIMARY KEY (DATE_KEY)
);

-- Federal vs. Massachusetts. Tiny, but it lets every fact be split by level of government.
CREATE OR REPLACE TABLE DIM_JURISDICTION (
  JURISDICTION_KEY     NUMBER       NOT NULL,
  JURISDICTION_CODE    VARCHAR(10),          -- 'US', 'MA'
  JURISDICTION_NAME    VARCHAR(100),         -- 'United States', 'Massachusetts'
  GOVERNMENT_LEVEL     VARCHAR(20),          -- 'Federal', 'State'
  CONSTRAINT PK_DIM_JURISDICTION PRIMARY KEY (JURISDICTION_KEY)
);

-- One row per agency (SCD Type 1: corrections overwrite).
CREATE OR REPLACE TABLE DIM_AGENCY (
  AGENCY_KEY           NUMBER       NOT NULL,
  FR_AGENCY_ID         NUMBER,               -- Federal Register agency id
  AGENCY_SLUG          VARCHAR(200),         -- e.g. occupational-safety-and-health-administration
  AGENCY_NAME          VARCHAR(500),
  AGENCY_ACRONYM       VARCHAR(20),          -- e.g. OSHA (matches Regulations.gov agencyId)
  PARENT_AGENCY_NAME   VARCHAR(500),         -- e.g. Labor Department
  CONSTRAINT PK_DIM_AGENCY PRIMARY KEY (AGENCY_KEY)
);

-- One row per regulation document (federal rule, proposed rule, or Massachusetts regulation). SCD Type 1.
CREATE OR REPLACE TABLE DIM_RULE (
  RULE_KEY             NUMBER       NOT NULL,
  DOCUMENT_NUMBER      VARCHAR(50),          -- natural key, e.g. 2025-12175 or '105 CMR 590'
  TITLE                VARCHAR(2000),
  DOCUMENT_TYPE        VARCHAR(30),          -- 'Rule', 'Proposed Rule', 'State Regulation'
  ACTION               VARCHAR(500),
  ABSTRACT             VARCHAR(16000),
  PRIMARY_RIN          VARCHAR(20),
  IS_SIGNIFICANT       BOOLEAN,
  HTML_URL             VARCHAR(1000),
  SOURCE_SYSTEM        VARCHAR(30),          -- 'Federal Register', 'mass.gov'
  CONSTRAINT PK_DIM_RULE PRIMARY KEY (RULE_KEY)
);

-- One row per Regulations.gov docket.
CREATE OR REPLACE TABLE DIM_DOCKET (
  DOCKET_KEY           NUMBER       NOT NULL,
  DOCKET_ID            VARCHAR(100),         -- e.g. OSHA-2021-0009
  AGENCY_ACRONYM       VARCHAR(20),          -- prefix of the docket id
  CONSTRAINT PK_DIM_DOCKET PRIMARY KEY (DOCKET_KEY)
);

-- One row per CFR part PER VERSION (SCD Type 2). Parts without eCFR history get one current row.
CREATE OR REPLACE TABLE DIM_CFR_PART (
  CFR_PART_KEY         NUMBER       NOT NULL,
  CFR_TITLE            NUMBER(3),
  CFR_PART             VARCHAR(20),
  CFR_CITATION         VARCHAR(30),          -- e.g. '29 CFR 1926'
  PART_NAME            VARCHAR(500),
  VALID_FROM           DATE,
  VALID_TO             DATE,                 -- 9999-12-31 for the current version
  IS_CURRENT           BOOLEAN,
  CONSTRAINT PK_DIM_CFR_PART PRIMARY KEY (CFR_PART_KEY)
);

-- One row per NAICS code, with the hierarchy flattened into columns (no snowflaking).
CREATE OR REPLACE TABLE DIM_INDUSTRY (
  INDUSTRY_KEY         NUMBER       NOT NULL,
  NAICS_CODE           VARCHAR(10),          -- e.g. 722515
  NAICS_TITLE          VARCHAR(500),
  NAICS_LEVEL          NUMBER(1),            -- 2 to 6 digits
  SECTOR_CODE          VARCHAR(10),          -- e.g. 72
  SECTOR_TITLE         VARCHAR(500),
  SUBSECTOR_CODE       VARCHAR(10),          -- e.g. 722
  INDUSTRY_GROUP_CODE  VARCHAR(10),          -- e.g. 7225
  DEMO_INDUSTRY        VARCHAR(50),          -- 'Restaurants and cafes', 'Construction', 'Retail' or NULL
  NAICS_VERSION        VARCHAR(10),          -- '2022'
  CONSTRAINT PK_DIM_INDUSTRY PRIMARY KEY (INDUSTRY_KEY)
);

-- One row per bill (federal or Massachusetts).
CREATE OR REPLACE TABLE DIM_BILL (
  BILL_KEY             NUMBER       NOT NULL,
  BILL_ID              VARCHAR(50),          -- e.g. 119-HR-1234
  SESSION_NAME         VARCHAR(100),         -- e.g. '119th Congress'
  BILL_TYPE            VARCHAR(10),
  BILL_NUMBER          VARCHAR(20),
  TITLE                VARCHAR(4000),
  ORIGIN_CHAMBER       VARCHAR(20),
  LATEST_ACTION_TEXT   VARCHAR(4000),
  BILL_URL             VARCHAR(1000),
  CONSTRAINT PK_DIM_BILL PRIMARY KEY (BILL_KEY)
);

-- One row per official Boston neighborhood (26).
CREATE OR REPLACE TABLE DIM_NEIGHBORHOOD (
  NEIGHBORHOOD_KEY     NUMBER       NOT NULL,
  NEIGHBORHOOD_NAME    VARCHAR(100),
  CITY                 VARCHAR(50),
  AREA_SQ_MILES        FLOAT,
  CENTROID_LAT         FLOAT,
  CENTROID_LON         FLOAT,
  CONSTRAINT PK_DIM_NEIGHBORHOOD PRIMARY KEY (NEIGHBORHOOD_KEY)
);

-- One row per ZIP code. ZIPs cross neighborhood lines, so the main neighborhood is an attribute.
CREATE OR REPLACE TABLE DIM_ZIP (
  ZIP_KEY                    NUMBER   NOT NULL,
  ZIP_CODE                   VARCHAR(5),
  CITY                       VARCHAR(50),
  PRIMARY_NEIGHBORHOOD_NAME  VARCHAR(100),
  CONSTRAINT PK_DIM_ZIP PRIMARY KEY (ZIP_KEY)
);

-- ---------------------------------------------------------------------
-- BRIDGE TABLES (many-to-many between a rule and a dimension)
-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE BRIDGE_RULE_AGENCY (
  RULE_KEY             NUMBER       NOT NULL,
  AGENCY_KEY           NUMBER       NOT NULL,
  AGENCY_ORDER         NUMBER(2),            -- 1 = primary (first-listed) agency
  CONSTRAINT PK_BRIDGE_RULE_AGENCY PRIMARY KEY (RULE_KEY, AGENCY_KEY),
  CONSTRAINT FK_BRA_RULE   FOREIGN KEY (RULE_KEY)   REFERENCES DIM_RULE (RULE_KEY),
  CONSTRAINT FK_BRA_AGENCY FOREIGN KEY (AGENCY_KEY) REFERENCES DIM_AGENCY (AGENCY_KEY)
);

CREATE OR REPLACE TABLE BRIDGE_RULE_CFR_PART (
  RULE_KEY             NUMBER       NOT NULL,
  CFR_PART_KEY         NUMBER       NOT NULL,  -- the part version in force on the rule's publication date
  CONSTRAINT PK_BRIDGE_RULE_CFR_PART PRIMARY KEY (RULE_KEY, CFR_PART_KEY),
  CONSTRAINT FK_BRC_RULE FOREIGN KEY (RULE_KEY)     REFERENCES DIM_RULE (RULE_KEY),
  CONSTRAINT FK_BRC_CFR  FOREIGN KEY (CFR_PART_KEY) REFERENCES DIM_CFR_PART (CFR_PART_KEY)
);

CREATE OR REPLACE TABLE BRIDGE_RULE_DOCKET (
  RULE_KEY             NUMBER       NOT NULL,
  DOCKET_KEY           NUMBER       NOT NULL,
  CONSTRAINT PK_BRIDGE_RULE_DOCKET PRIMARY KEY (RULE_KEY, DOCKET_KEY),
  CONSTRAINT FK_BRD_RULE   FOREIGN KEY (RULE_KEY)   REFERENCES DIM_RULE (RULE_KEY),
  CONSTRAINT FK_BRD_DOCKET FOREIGN KEY (DOCKET_KEY) REFERENCES DIM_DOCKET (DOCKET_KEY)
);

-- Filled later by Cortex industry tagging.
CREATE OR REPLACE TABLE BRIDGE_RULE_INDUSTRY (
  RULE_KEY             NUMBER       NOT NULL,
  INDUSTRY_KEY         NUMBER       NOT NULL,
  RELEVANCE_SCORE      FLOAT,                -- 0 to 1
  TAG_METHOD           VARCHAR(30),          -- 'cortex', 'keyword', 'manual'
  TAGGED_AT            TIMESTAMP_NTZ,
  CONSTRAINT PK_BRIDGE_RULE_INDUSTRY PRIMARY KEY (RULE_KEY, INDUSTRY_KEY),
  CONSTRAINT FK_BRI_RULE     FOREIGN KEY (RULE_KEY)     REFERENCES DIM_RULE (RULE_KEY),
  CONSTRAINT FK_BRI_INDUSTRY FOREIGN KEY (INDUSTRY_KEY) REFERENCES DIM_INDUSTRY (INDUSTRY_KEY)
);

-- ---------------------------------------------------------------------
-- FACTS: REGULATION STAR
-- ---------------------------------------------------------------------

-- Accumulating snapshot. Grain: one row per regulation document.
CREATE OR REPLACE TABLE FACT_RULE (
  RULE_KEY                       NUMBER NOT NULL,
  PRIMARY_AGENCY_KEY             NUMBER,
  JURISDICTION_KEY               NUMBER,
  PUBLICATION_DATE_KEY           NUMBER(8),
  EFFECTIVE_DATE_KEY             NUMBER(8),
  COMMENT_START_DATE_KEY         NUMBER(8),
  COMMENT_END_DATE_KEY           NUMBER(8),
  DAYS_PUBLICATION_TO_EFFECTIVE  NUMBER,
  COMMENT_PERIOD_DAYS            NUMBER,
  AGENCY_COUNT                   NUMBER,
  CFR_PART_COUNT                 NUMBER,
  DOCKET_COUNT                   NUMBER,
  HAS_RIN                        BOOLEAN,
  IS_OPEN_FOR_COMMENT            BOOLEAN,
  MATCHED_TO_REGULATIONS_GOV     BOOLEAN,
  RULE_COUNT                     NUMBER DEFAULT 1,
  CONSTRAINT PK_FACT_RULE PRIMARY KEY (RULE_KEY),
  CONSTRAINT FK_FR_RULE      FOREIGN KEY (RULE_KEY)               REFERENCES DIM_RULE (RULE_KEY),
  CONSTRAINT FK_FR_AGENCY    FOREIGN KEY (PRIMARY_AGENCY_KEY)     REFERENCES DIM_AGENCY (AGENCY_KEY),
  CONSTRAINT FK_FR_JURIS     FOREIGN KEY (JURISDICTION_KEY)       REFERENCES DIM_JURISDICTION (JURISDICTION_KEY),
  CONSTRAINT FK_FR_PUB_DATE  FOREIGN KEY (PUBLICATION_DATE_KEY)   REFERENCES DIM_DATE (DATE_KEY),
  CONSTRAINT FK_FR_EFF_DATE  FOREIGN KEY (EFFECTIVE_DATE_KEY)     REFERENCES DIM_DATE (DATE_KEY),
  CONSTRAINT FK_FR_CS_DATE   FOREIGN KEY (COMMENT_START_DATE_KEY) REFERENCES DIM_DATE (DATE_KEY),
  CONSTRAINT FK_FR_CE_DATE   FOREIGN KEY (COMMENT_END_DATE_KEY)   REFERENCES DIM_DATE (DATE_KEY)
);

-- Transaction fact. Grain: one row per eCFR section version (one change to one section).
CREATE OR REPLACE TABLE FACT_CFR_CHANGE (
  CFR_CHANGE_ID        NUMBER       NOT NULL,
  CFR_PART_KEY         NUMBER,
  JURISDICTION_KEY     NUMBER,
  CHANGE_DATE_KEY      NUMBER(8),
  AMENDMENT_DATE_KEY   NUMBER(8),
  SECTION_IDENTIFIER   VARCHAR(50),          -- degenerate dimension, e.g. 1926.501
  IS_SUBSTANTIVE       BOOLEAN,
  IS_REMOVED           BOOLEAN,
  CHANGE_COUNT         NUMBER DEFAULT 1,
  CONSTRAINT PK_FACT_CFR_CHANGE PRIMARY KEY (CFR_CHANGE_ID),
  CONSTRAINT FK_FCC_CFR      FOREIGN KEY (CFR_PART_KEY)       REFERENCES DIM_CFR_PART (CFR_PART_KEY),
  CONSTRAINT FK_FCC_JURIS    FOREIGN KEY (JURISDICTION_KEY)   REFERENCES DIM_JURISDICTION (JURISDICTION_KEY),
  CONSTRAINT FK_FCC_CHG_DATE FOREIGN KEY (CHANGE_DATE_KEY)    REFERENCES DIM_DATE (DATE_KEY),
  CONSTRAINT FK_FCC_AMD_DATE FOREIGN KEY (AMENDMENT_DATE_KEY) REFERENCES DIM_DATE (DATE_KEY)
);

-- Grain: one row per bill (federal now, Massachusetts when LegiScan arrives).
CREATE OR REPLACE TABLE FACT_BILL (
  BILL_KEY                    NUMBER   NOT NULL,
  JURISDICTION_KEY            NUMBER,
  LATEST_ACTION_DATE_KEY      NUMBER(8),
  UPDATE_DATE_KEY             NUMBER(8),
  IS_SMALL_BUSINESS_RELEVANT  BOOLEAN,
  BILL_COUNT                  NUMBER DEFAULT 1,
  CONSTRAINT PK_FACT_BILL PRIMARY KEY (BILL_KEY),
  CONSTRAINT FK_FB_BILL     FOREIGN KEY (BILL_KEY)               REFERENCES DIM_BILL (BILL_KEY),
  CONSTRAINT FK_FB_JURIS    FOREIGN KEY (JURISDICTION_KEY)       REFERENCES DIM_JURISDICTION (JURISDICTION_KEY),
  CONSTRAINT FK_FB_ACT_DATE FOREIGN KEY (LATEST_ACTION_DATE_KEY) REFERENCES DIM_DATE (DATE_KEY),
  CONSTRAINT FK_FB_UPD_DATE FOREIGN KEY (UPDATE_DATE_KEY)        REFERENCES DIM_DATE (DATE_KEY)
);

-- ---------------------------------------------------------------------
-- FACTS: LOCATION STAR
-- ---------------------------------------------------------------------

-- Periodic snapshot. Grain: one row per neighborhood per snapshot date.
CREATE OR REPLACE TABLE FACT_NEIGHBORHOOD_PROFILE (
  NEIGHBORHOOD_KEY          NUMBER   NOT NULL,
  SNAPSHOT_DATE_KEY         NUMBER(8) NOT NULL,
  ACS_YEAR                  NUMBER(4),
  RESIDENTS                 NUMBER,
  RESIDENTS_18_34           NUMBER,
  MEDIAN_HOUSEHOLD_INCOME   NUMBER,          -- non-additive: never SUM across neighborhoods
  COLLEGE_COUNT             NUMBER,
  STUDENTS_NEARBY           NUMBER,
  TRANSIT_STATION_COUNT     NUMBER,
  TRANSIT_LINE_COUNT        NUMBER,
  FOOD_ESTABLISHMENT_COUNT  NUMBER,
  CONSTRAINT PK_FACT_NEIGHBORHOOD_PROFILE PRIMARY KEY (NEIGHBORHOOD_KEY, SNAPSHOT_DATE_KEY),
  CONSTRAINT FK_FNP_HOOD FOREIGN KEY (NEIGHBORHOOD_KEY)  REFERENCES DIM_NEIGHBORHOOD (NEIGHBORHOOD_KEY),
  CONSTRAINT FK_FNP_DATE FOREIGN KEY (SNAPSHOT_DATE_KEY) REFERENCES DIM_DATE (DATE_KEY)
);

-- Periodic snapshot. Grain: one row per ZIP code per industry per year (Census business counts).
CREATE OR REPLACE TABLE FACT_BUSINESS_COUNT (
  ZIP_KEY              NUMBER       NOT NULL,
  INDUSTRY_KEY         NUMBER       NOT NULL,
  YEAR_DATE_KEY        NUMBER(8)    NOT NULL,  -- January 1 of the data year
  ESTABLISHMENTS       NUMBER,
  CONSTRAINT PK_FACT_BUSINESS_COUNT PRIMARY KEY (ZIP_KEY, INDUSTRY_KEY, YEAR_DATE_KEY),
  CONSTRAINT FK_FBC_ZIP      FOREIGN KEY (ZIP_KEY)       REFERENCES DIM_ZIP (ZIP_KEY),
  CONSTRAINT FK_FBC_INDUSTRY FOREIGN KEY (INDUSTRY_KEY)  REFERENCES DIM_INDUSTRY (INDUSTRY_KEY),
  CONSTRAINT FK_FBC_DATE     FOREIGN KEY (YEAR_DATE_KEY) REFERENCES DIM_DATE (DATE_KEY)
);

-- Factless fact. Grain: one row per licensed food establishment.
CREATE OR REPLACE TABLE FACT_ESTABLISHMENT (
  ESTABLISHMENT_ID          VARCHAR(50) NOT NULL,  -- degenerate dimension (license id)
  NEIGHBORHOOD_KEY          NUMBER,
  ZIP_KEY                   NUMBER,
  INDUSTRY_KEY              NUMBER,
  LICENSE_ADDED_DATE_KEY    NUMBER(8),
  BUSINESS_NAME             VARCHAR(500),
  LATITUDE                  FLOAT,
  LONGITUDE                 FLOAT,
  ESTABLISHMENT_COUNT       NUMBER DEFAULT 1,
  CONSTRAINT PK_FACT_ESTABLISHMENT PRIMARY KEY (ESTABLISHMENT_ID),
  CONSTRAINT FK_FE_HOOD     FOREIGN KEY (NEIGHBORHOOD_KEY)       REFERENCES DIM_NEIGHBORHOOD (NEIGHBORHOOD_KEY),
  CONSTRAINT FK_FE_ZIP      FOREIGN KEY (ZIP_KEY)                REFERENCES DIM_ZIP (ZIP_KEY),
  CONSTRAINT FK_FE_INDUSTRY FOREIGN KEY (INDUSTRY_KEY)           REFERENCES DIM_INDUSTRY (INDUSTRY_KEY),
  CONSTRAINT FK_FE_DATE     FOREIGN KEY (LICENSE_ADDED_DATE_KEY) REFERENCES DIM_DATE (DATE_KEY)
);

SHOW TABLES IN SCHEMA REGRADAR_DB.GOLD;
