# Health Client Renewal & Retention — AtScale SML model

An AtScale SML repository for an employer health-benefits client book (ASO + insured). It covers renewals and retention, rate actions and broker concessions, product cross-sell at renewal, membership and revenue trend, loss ratio and the GLP-1 pharmacy trend, and the service experience before renewal. Client data is secured by a group-based row security object on `client_id`, with Secure Totals on.

## Inputs

All inputs arrived as one archive, `health_client_retention_context.zip`. The archive is copied verbatim into `context/` and its files are extracted alongside it.

| Input | File | Description |
|---|---|---|
| Use case | `context/use_case.md` | Scenario, personas, NLQs (R1, R2, L1, L2, G1, G2, S1, S2), measure semantics, row-security setup |
| NLQs | embedded in `context/use_case.md` | The "Brief NLQs" section. No separate NLQ file |
| DDL | `context/02_ddl.sql` | Databricks SQL / Delta (Unity Catalog) DDL: 5 dimensions, 1 row-security map, 4 facts |
| ERD | `context/erd.mmd` | Mermaid erDiagram with the intended joins and role-played date FKs |
| Data profile | `context/data_profile.yaml` | Column-level profile (seed 42): row counts, distinct counts, measure_kind |
| Target warehouse | derived | Databricks (from the use case, profile `warehouse: databricks`, and the DDL) |
| build.yaml | (not provided) | |
| Existing SML | (not provided) | |

## Build parameters

| Parameter | Value |
|---|---|
| `unrelated_dimension_handling` | `repeat` |
| `warehouse` | Databricks (`as_connection: Databricks`) |
| `database` / `schema` | `main` / `health_client_retention` |
| `model_unique_name` | `health_client_retention` |
| `catalog_unique_name` | `health_client_retention_catalog` |
| `currency` | USD |
| `time_window` | calendar |
| `use_cases_covered` | all (R1, R2, L1, L2, G1, G2, S1, S2) |
| `use_cases_excluded` | none |
| `semi_additive_default` | `fact_client_month` members/subscribers → last_non_empty over Snapshot date. All other measures are additive sums, or averages for non-additive pct/score columns |

## Assumptions and decisions

- **warehouse = Databricks**: stated in the use case ("Databricks (Unity Catalog)") and the data profile. All DB identifiers are lowercase.
- **database = main, schema = health_client_retention**: the DDL parameterizes catalog and schema as loader variables. The defaults come from the use case's note that `load.sh` defaults to `main.health_client_retention`. Override them in `connections/Connection - Health Client Retention.yml` if you loaded the data elsewhere.
- **model_unique_name = health_client_retention**: from the use case slug. The catalog is `health_client_retention_catalog` (Rule 8c).
- **currency = USD**: stated in the use case. **time_window = calendar**: there are no fiscal or retail markers.
- **unrelated_dimension_handling = repeat**: the skill default, applied to every base metric. No build.yaml was provided.
- **Customer name**: no customer name appears in the inputs. All logical names are domain-generic (Rule 18).
- **Date role-plays**: Snapshot (`fact_client_month.snapshot_date_key`), Renewal (`fact_renewal` and `fact_renewal_product` `renewal_date_key`), Opened and Closed (`fact_service_case`). All join the Day level (`date_key`).
- **Date hierarchy keys**: added the calculated columns `year_quarter` (year*10+q) and `year_month_num` (year*100+m) to `dim_date`. They give unique, correctly sortable Quarter and Month keys. `prior_year_num` was also added, and `parallel_periods` are set on Quarter, Month and Day for ParallelPeriod prior-year calcs (Rule 13).
- **Time-intelligence axis (Rule 4)**: revenue, member and loss-ratio prior-year/YTD calcs use the Snapshot date. Retention and renewal calcs use the Renewal date.
- **Members / Subscribers**: `sum` + `semi_additive: last` over the Snapshot date relationship, so a balance is never summed across months (Rule 19). They sum correctly across clients and products.
- **Broker and Account Manager** are embedded in the Client dimension from `dim_client.broker_id` / `account_manager_id`, so every fact (membership, renewals, product changes, cases) can be sliced by broker. `fact_renewal.broker_id` / `account_manager_id` are kept in the dataset but not joined. The use case states the broker of record is static per client, so both paths give identical results, and a single path avoids ambiguous joins.
- **Row security**: `row_security/Client Offshore Access.yml` follows `sml-spec/row-security.md` and the use-case configuration: dataset `sec_client_group_map`, filter key `client_id`, IDs `group_name`, ID type `group`, scope `all`, Secure Totals `true`, and `use_filter_key: false` (Lookup Rules = None). Try `true` on Databricks for performance. It is attached to the Client dimension with one embedded relationship per Client hierarchy, all on the shared Client leaf (use case step 4). Create the groups `client_analytics_onshore` and `client_analytics_offshore` in the IdP and put every demo user in one of them.
- **Client hierarchies**: Segment, Funding Arrangement, Industry, and Region > HQ State all share the Client leaf level. Client attributes (Risk Basis, Employee Band, Client Status, Offshore Access, Restriction Reason, Renewal Month, effective and termination dates) are secondary attributes on the Client level of the Segment Hierarchy. They are keyed on their own columns (Rule 8b pattern B, as in Internet Sales Customer Dimension) so they group cleanly.
- **Calculated string columns** turn booleans and NULLs into readable members: `risk_basis`, `offshore_access`, `restriction_reason` (dim_client), `specialty_flag` (dim_product), `lost_reason_label`, `competitor_won_label`, `escalation_band` (0-2 vs 3+, for NLQ L2), `rate_action_band` (fact_renewal), and `escalation_status` (fact_service_case).
- **Calculated flag columns** make the use-case counts expressible as sums: `added_flag`, `dropped_flag`, `added_revenue` (fact_renewal_product), `offshore_case_flag`, `open_case_flag` (fact_service_case), `insured_renewal_count` (fact_renewal), and `total_claims` (fact_client_month).
- **Degenerate dimensions** (Rule 12): Renewal Outcome (fact_renewal), Product Change (fact_renewal_product), and Service Case (fact_service_case). They are listed in the model `dimensions:` block, marked `is_degenerate: true`, and have no `is_unique_key`.
- **is_unique_key** (Rule 16): set only where the profile shows distinct == rows. That is Day (`date_key` 1096/1096), Client (715/715), Broker (24/24), Account Manager (32/32) and Product (7/7).
- **Percentage-point columns**: `*_increase_pct` and `rate_concession_pts` are stored as points (e.g. 6.5), so they are formatted as numbers, not `percent`. `prior_12m_loss_ratio` is a fraction (0.87), so it is formatted `0.0%`.
- **Non-additive columns** (`prior_12m_loss_ratio`, `*_pct`, `days_to_resolve`, `csat_score`) use `average`, as the use case directs. Pooled versions are calculated from components: Prior 12M Loss Ratio (pooled), Loss Ratio, and Rate Concession Pts = Avg Proposed − Avg Final.
- **G1 "top 20 clients"**: ranking (TopCount) is not supported in AtScale MDX (INDEX.md), so no ranking calc is emitted. The model exposes Members and Total Revenue by Client, and the BI/NLQ layer sorts and limits. This is not a fail-fast, because the question is answerable by sort/limit without an MDX ranking function.
- **`products_before` / `products_after`** (non-additive per-renewal counts) are not exposed as metrics. Products Added/Dropped cover the cross-sell NLQs.

## Generation summary

- Datasets: 10 (9 table-backed model datasets + sec_client_group_map for row security)
- Dimensions: 8 (5 standard/time incl. Date, 3 degenerate)
- Base metrics: 41
- Calculated metrics: 23
- Model relationships: 11
- Row security objects: 1

- **Role-play prefixes**: `Snapshot {0}`, `Renewal {0}`, `Opened {0}`, `Closed {0}` on Date Dimension
- **Snowflake bridges**: none (Broker and Account Manager are embedded dimensions on Client)
- **Semi-additive**: Members, Subscribers (last non-empty over Snapshot date)
- **Calculated columns**: 3 on dim_date, 1 on dim_product, 3 on dim_client, 1 on fact_client_month, 7 on fact_renewal, 3 on fact_renewal_product, 4 on fact_service_case
- **NLQ coverage**: R1 Retention Rate × Segment × Renewal Year · R2 Avg Proposed/Final Increase Pct and Rate Concession Pts × Broker · L1 Loss Ratio × Product × Risk Basis × Snapshot Year, Prior 12M Loss Ratio, Avg Final Increase Pct, Lost Count × Lost Reason · L2 Retention Rate × Escalation Band, Lost Reason · G1 Members / Total Revenue × Client × Snapshot Month · G2 Products Added × Product × Change Type, Avg Revenue per Product Add · S1 Total Revenue / Clients In Force / Members (row security) · S2 Offshore Handled Cases × Offshore Access
- **Caveats**: Row security must be enforced with real IdP groups. Unmapped users are undefined behavior per the use case. Avg Final Increase Pct for "lost on price" clients requires filtering Lost Reason = Price / Rate Increase.

## Reproducing this build

`context/` holds verbatim copies of every input: the original `health_client_retention_context.zip` plus its extracted `use_case.md`, `02_ddl.sql`, `erd.mmd` and `data_profile.yaml`. No build.yaml was used, and every derived value is logged above. Re-running the atscale-sml-model-generator skill on the same archive with default build parameters should produce an equivalent model. The emitter script is `hcr_emit.py`, kept next to the model build folder.
