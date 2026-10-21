-- 02_ddl.sql — health_client_retention schema (Databricks SQL / Delta, Unity Catalog)
-- 5 dimensions + 1 row-security mapping table + 4 facts.
--
-- Databricks notes:
--   * Types: ids/counts BIGINT, money DECIMAL(18,2), ratios/pcts DOUBLE,
--     strings STRING, dates DATE, flags BOOLEAN.
--   * PRIMARY KEY is declared (informational / NOT ENFORCED on Unity Catalog).
--   * FOREIGN KEYs are kept as comments; AtScale defines the joins in the model.
--   * Date FKs are YYYYMMDD BIGINT keys into dim_date.date_key (role-played:
--     snapshot / renewal / case opened / case closed).
--   * Facts use liquid clustering (CLUSTER BY); requires DBR 13.3+. Safe to remove.
--   * CREATE OR REPLACE makes this idempotent (also resets COPY INTO load history).
-- ${CATALOG} / ${SCHEMA} are substituted by load.sh.

-- ============================================================
-- Dimensions
-- ============================================================
CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.dim_date (
  date_key        BIGINT NOT NULL,     -- YYYYMMDD
  calendar_date   DATE,
  year_num        BIGINT,
  quarter_num     BIGINT,
  quarter_name    STRING,              -- 'Q1 2025'
  month_num       BIGINT,
  month_name      STRING,
  year_month      STRING,              -- 'YYYY-MM'
  day_of_month    BIGINT,
  day_name        STRING,
  is_month_end    BOOLEAN,             -- snapshot dates
  is_month_start  BOOLEAN,             -- renewal effective dates
  CONSTRAINT dim_date_pk PRIMARY KEY (date_key)
);

CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.dim_product (
  product_id            BIGINT NOT NULL,
  product_name          STRING,        -- Medical, Pharmacy, Behavioral Health, Dental, Vision, Stop-Loss, Supplemental Health
  product_category      STRING,
  is_specialty_product  BOOLEAN,
  CONSTRAINT dim_product_pk PRIMARY KEY (product_id)
);

CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.dim_broker (
  broker_id    BIGINT NOT NULL,
  broker_name  STRING,
  broker_type  STRING,                 -- National Consultant | Regional Broker | Local Broker | Direct
  CONSTRAINT dim_broker_pk PRIMARY KEY (broker_id)
);

CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.dim_account_manager (
  account_manager_id    BIGINT NOT NULL,
  account_manager_name  STRING,
  account_team          STRING,        -- National Accounts Team | Middle Market Team | Select Team
  am_region             STRING,
  CONSTRAINT dim_account_manager_pk PRIMARY KEY (account_manager_id)
);

CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.dim_client (
  client_id                    BIGINT NOT NULL,   -- employer client (row-security filter key)
  client_name                  STRING,
  segment                      STRING,            -- National Accounts | Middle Market | Select
  funding_arrangement          STRING,            -- ASO | Guaranteed Cost | Level Funded
  is_insured                   BOOLEAN,           -- carrier bears claim risk (GC / Level Funded)
  industry                     STRING,
  employee_band                STRING,
  hq_state                     STRING,
  region                       STRING,
  broker_id                    BIGINT,            -- FK dim_broker (broker of record)
  account_manager_id           BIGINT,            -- FK dim_account_manager
  renewal_month                BIGINT,            -- plan-year anniversary month (1-12)
  original_effective_date      DATE,
  termination_date             DATE,              -- NULL while active
  client_status                STRING,            -- Active | Terminated
  offshore_access_allowed      BOOLEAN,           -- FALSE = onshore-only data access (RLS)
  offshore_restriction_reason  STRING,            -- NULL when offshore access is allowed
  CONSTRAINT dim_client_pk PRIMARY KEY (client_id)
);

-- ============================================================
-- Row-security mapping (AtScale group-based row security object)
--   Filter key = client_id, IDs = group_name, ID Type = Group.
--   client_analytics_onshore  -> every client
--   client_analytics_offshore -> only clients with offshore_access_allowed = TRUE
-- ============================================================
CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.sec_client_group_map (
  client_id   BIGINT NOT NULL,                   -- FK dim_client
  group_name  STRING NOT NULL,                   -- lowercase AtScale group id
  CONSTRAINT sec_client_group_map_pk PRIMARY KEY (client_id, group_name)
);

-- ============================================================
-- Facts
-- ============================================================
-- Monthly snapshot: client x product x month-end
CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.fact_client_month (
  client_month_id       BIGINT NOT NULL,
  snapshot_date_key     BIGINT,          -- FK dim_date (month-end)
  client_id             BIGINT,          -- FK dim_client
  product_id            BIGINT,          -- FK dim_product
  members               BIGINT,          -- SEMI-ADDITIVE (enrolled at month-end)
  subscribers           BIGINT,          -- SEMI-ADDITIVE
  member_months         BIGINT,          -- additive
  premium_revenue       DECIMAL(18,2),   -- insured premium (GC / Level Funded, stop-loss, voluntary)
  admin_fee_revenue     DECIMAL(18,2),   -- ASO administrative fees
  total_revenue         DECIMAL(18,2),   -- premium + admin fees
  insured_claims        DECIMAL(18,2),   -- carrier-borne incurred claims
  client_funded_claims  DECIMAL(18,2),   -- ASO claims paid on the employer's behalf
  glp1_rx_claims        DECIMAL(18,2),   -- GLP-1 portion of pharmacy claims (either funding)
  CONSTRAINT fact_client_month_pk PRIMARY KEY (client_month_id)
) CLUSTER BY (snapshot_date_key, client_id);

-- One row per client renewal (plan-year anniversary)
CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.fact_renewal (
  renewal_id                 BIGINT NOT NULL,
  client_id                  BIGINT,          -- FK dim_client
  broker_id                  BIGINT,          -- FK dim_broker (broker at renewal)
  account_manager_id         BIGINT,          -- FK dim_account_manager
  renewal_date_key           BIGINT,          -- FK dim_date (effective date, 1st of month)
  plan_year                  BIGINT,
  members_at_renewal         BIGINT,
  prior_12m_revenue          DECIMAL(18,2),   -- revenue in the 12 months before renewal
  prior_12m_insured_premium  DECIMAL(18,2),
  prior_12m_insured_claims   DECIMAL(18,2),
  prior_12m_loss_ratio       DOUBLE,          -- insured clients only; NULL for ASO
  service_cases_prior_12m    BIGINT,
  escalations_prior_12m      BIGINT,
  proposed_increase_pct      DOUBLE,          -- underwriting proposal (rate, or admin fee for ASO)
  final_increase_pct         DOUBLE,          -- negotiated outcome
  rate_concession_pts        DOUBLE,          -- proposed - final
  renewal_outcome            STRING,          -- Renewed | Lost
  is_retained                BOOLEAN,
  renewal_count              BIGINT,          -- always 1 (additive count)
  retained_count             BIGINT,          -- 1 / 0
  lost_count                 BIGINT,          -- 1 / 0
  lost_reason                STRING,          -- NULL when renewed
  competitor_won             STRING,          -- NULL when renewed or M&A
  revenue_retained           DECIMAL(18,2),
  revenue_lost               DECIMAL(18,2),
  products_before            BIGINT,
  products_after             BIGINT,
  products_added             BIGINT,
  products_dropped           BIGINT,
  CONSTRAINT fact_renewal_pk PRIMARY KEY (renewal_id)
) CLUSTER BY (renewal_date_key, client_id);

-- Renewal x product change
CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.fact_renewal_product (
  renewal_product_id  BIGINT NOT NULL,
  renewal_id          BIGINT,          -- FK fact_renewal
  client_id           BIGINT,          -- FK dim_client
  product_id          BIGINT,          -- FK dim_product
  renewal_date_key    BIGINT,          -- FK dim_date
  change_type         STRING,          -- Retained | Added | Dropped | Terminated
  is_added            BOOLEAN,
  is_dropped          BOOLEAN,
  est_annual_revenue  DECIMAL(18,2),
  CONSTRAINT fact_renewal_product_pk PRIMARY KEY (renewal_product_id)
) CLUSTER BY (renewal_date_key, product_id);

-- One row per service case
CREATE OR REPLACE TABLE `${CATALOG}`.`${SCHEMA}`.fact_service_case (
  case_id           BIGINT NOT NULL,
  client_id         BIGINT,          -- FK dim_client
  opened_date_key   BIGINT,          -- FK dim_date
  closed_date_key   BIGINT,          -- FK dim_date; NULL while open
  case_category     STRING,
  priority          STRING,          -- Low | Medium | High | Critical
  is_escalated      BOOLEAN,         -- executive escalation to the account team
  case_status       STRING,          -- Open | Closed
  days_to_resolve   DOUBLE,          -- NULL while open
  handled_location  STRING,          -- Onshore | Offshore
  service_center    STRING,
  csat_score        BIGINT,          -- 1-5; NULL while open
  case_count        BIGINT,          -- always 1
  escalation_count  BIGINT,          -- 1 / 0
  CONSTRAINT fact_service_case_pk PRIMARY KEY (case_id)
) CLUSTER BY (opened_date_key, client_id);
