# Health Client Renewal & Retention — Use Case

**Slug:** `health_client_retention`
**Vertical:** US employer health benefits (carrier with ASO + insured books)
**Target platform:** Databricks (Unity Catalog). The target is left generic: `${CATALOG}`.`${SCHEMA}`, with `load.sh` defaulting to `main.health_client_retention`.
**Currency:** USD (single currency, no FX)
**Window:** 2023-10-01 → 2026-09-30 (36 monthly snapshots through 2026-09). The generator runs a 12-month burn-in that is never emitted, so early renewals have full prior-year experience.
**Data strategy:** Tier 3, bespoke synthetic. Fully fictional and brand-neutral, so it can be reused across accounts.

> **Generic and reusable.** No customer or prospect name appears in the slug, schema,
> table or column names, or any data value. All client, broker, competitor and staff names are fictional.
> The bundle was shaped for a demo to a large US health-benefits carrier
> (the employer-client view of an ASO and insured commercial book).

## Scenario

An account-management and underwriting leadership team wants one governed view of its
**employer client book**. That means renewals, retention, rate actions, broker negotiation, cross-sell,
membership and revenue trend, and the service experience that precedes a renewal.

Every row of client data is tied to a **`client_id`**. Some employer clients forbid
**offshore resources** from accessing their data. This is a contractual clause for most of them, and a hard requirement for
public-sector and federal-contractor clients. The semantic layer enforces this with an **AtScale
group-based row security object** keyed on `client_id`. Onshore analysts see the full book.
Offshore analysts ask the same questions and get answers computed only over clients that allow
offshore access. This includes totals, because Secure Totals is on.

## Brief NLQs (what the data is shaped to answer)

### Retention by segment and broker
- **R1** *"What is our client retention rate by segment over the last 3 years?"*
  `fact_renewal.retained_count / renewal_count` by `dim_client.segment` and renewal year.
  National Accounts runs about 89–97% and Middle Market about 89–91%. **Select falls from 81% (2024) to 80% (2025) to 69% (2026).**
- **R2** *"How do proposed vs final rate increases compare by broker?"*
  This is `proposed_increase_pct` against `final_increase_pct` by `dim_broker`. **Keystone Benefit Partners** wins
  about **6.1 pts** of concessions per renewal, against about 1–3 pts for every other broker. National consultants show
  small numbers because their ASO clients' increases are admin-fee increases (about 3%).

### Why we lost clients
- **L1** *"Why did we lose Select clients in 2026?"* This is an engineered causal chain:
  1. **GLP-1 pharmacy trend.** On Select insured clients (Guaranteed Cost and Level Funded), the pharmacy loss ratio goes from
     **91% (2024) to 111% (2025) to 125% (2026)**. GLP-1 rises from 14% to 40% of Rx claims (`glp1_rx_claims`). Medical stays
     roughly flat at 86–89%. The total Select insured loss ratio goes from **86% to 92%**.
  2. **Experience-rated renewals.** On Select insured renewals, the prior-12-month loss ratio goes from 85% to 88% to 93%, and the average
     final increase goes from **4.7% to 7.3% to 11.3%**.
  3. **Price-driven lapse.** Select insured retention goes from 80% to 79% to **63%**. In 2026, **Price / Rate Increase
     accounts for 43 of 66 Select losses (about 65%)**, with an average final increase of about 17% on those clients.
- **L2** *"Do clients with service escalations churn more?"*
  Clients with **3 or more executive escalations in the 12 months before renewal retain about 65%**, against about 86–87% for
  clients with 0–2. "Service Issues" is the lost reason for 37 of them. Escalations are recorded both at case grain
  (`fact_service_case.is_escalated`) and pre-aggregated on the renewal (`escalations_prior_12m`).

### Growth, cross-sell and row security
- **G1** *"Show member and revenue trend for our top 20 clients."*
  These are the top 20 in-force clients by October 2023 membership. **Heritage Clinical Partners grows +40%** in members
  through acquisitions. **Greystone Aerospace shrinks −25%** through workforce reductions.
- **G2** *"Which products do retained clients add at renewal?"*
  This uses `fact_renewal_product.change_type = 'Added'`. **Behavioral Health is the #1 add (109)**, about 2.5× the next
  product. Pharmacy carve-ins carry the most added revenue per add.
- **S1** *"What is total revenue across all clients?"* (the row-security demo)
  Run it as an onshore user and then as an offshore user:

  | Group | Clients in force (2025) | 2025 revenue | Medical members (Dec 2025) |
  |---|---|---|---|
  | `client_analytics_onshore` | 557 | **$5.62B** | 4.42M |
  | `client_analytics_offshore` | 259 (~46%) | **$1.91B (~34%)** | 1.03M (~23%) |

  Restricted clients skew toward large National Accounts (80% restricted) and public-sector or defense clients
  (100% restricted). So about half the clients are hidden from offshore users, but about two-thirds of revenue is.
- **S2** *"Are restricted clients' service cases kept onshore?"*
  Restricted clients have **0 offshore-handled cases**. About 56% of allowed clients' cases are worked offshore,
  in Manila or Hyderabad.

Engineered narratives that run underneath all of this:
- Q4 claims seasonality
- Medical trend of 7.2% a year
- Small groups are noisier than large ones
- Executive escalations are always routed onshore
- New sales arrive at about 4 a month, effective on the 1st

## Row-level security in AtScale (group-based, on `client_id`)

AtScale row security objects restrict which rows a user or group can see. They join a
**security dataset** that maps IDs to attribute values against the dimensions or datasets they secure. This bundle ships the
security dataset ready to use:

`sec_client_group_map (client_id BIGINT, group_name STRING)` contains 1,056 rows:
- `client_analytics_onshore` maps to all 715 clients.
- `client_analytics_offshore` maps to the 341 clients with `dim_client.offshore_access_allowed = TRUE`.

Configure it in Design Center as follows:

1. **Datasources** panel → find `sec_client_group_map` → context menu → **Create Row Security**.
2. Fill in the **Row security properties**:
   - **Display Name / Unique Name:** `Client Offshore Access`. The unique name must be unique across all
     repositories and sub-repositories.
   - **Dataset:** `sec_client_group_map`
   - **Attribute Filter Keys:** `client_id`, the column that defines which rows each group can access.
   - **IDS:** `group_name`
   - **ID Type:** **Group**
   - **Scope:** **All**. Every query that has a path to the object is secured, including "total revenue" with no client
     attribute selected. (*Related* would only secure queries that select client attributes. *Fact* also covers
     metrics when the secured dimension is in the query. *Fact Only* requires connecting to a fact dataset.)
   - **Secure Totals:** **Enabled**. Subtotals and grand totals are then computed only over permitted
     clients, so an offshore user can't infer restricted revenue from totals.
   - **Lookup Rules:** *None*, which joins to the security table, or *Use Filter Key*, which looks up the permitted
     `client_id`s first and then filters the fact query. Some warehouses perform better with *Use Filter Key*, so it's worth
     comparing on Databricks.
3. Click **Apply**. The object appears in the Workspace `security/` folder.
4. **Attach it to the Client dimension.** Open the dimension's canvas, right-click the row security object in the
   Workspace panel, choose **Add to Dimension**, and connect `dim_client.client_id` to it. If the Client dimension has
   several hierarchies, give them the same leaf level (`client_id`) so a relationship is created for each.
   Don't attach it to a degenerate dimension. Connect to the dataset instead.
5. Create the groups `client_analytics_onshore` and `client_analytics_offshore` in AtScale's identity provider and put the
   demo users in them, for example an onshore analyst and an offshore analyst. Group IDs must match `group_name` exactly.

Gotchas from the AtScale docs:
- A row security object that **isn't connected to a dimension or dataset isn't enforced**. Re-check after editing.
- You **can't change the dataset** of an existing row security object. You can only swap its two columns.
- **Superusers are subject to row security.** Usernames must be lowercase unless `auth.user.normalize.lowercase` is set.
- Every user who queries the model must map through the security dataset. Here that happens through group membership.
  The docs don't spell out what happens for unmapped users, so put every demo user in one of the two groups.
- Row-security constraints are applied at runtime and **don't show up on the AtScale Queries page**.
- Deleting the object from a catalog removes it from every model in that catalog.

## Grain & semantics

| Table | Grain | Notes |
|---|---|---|
| `dim_date` | calendar day | `date_key` YYYYMMDD. Role-played: snapshot (month-end), renewal (1st of month), case opened/closed |
| `dim_client` | employer client ever in force during the window | segment, funding arrangement, industry, region, broker, AM, `offshore_access_allowed` |
| `dim_product` | benefit product | Medical, Pharmacy, Behavioral Health, Dental, Vision, Stop-Loss, Supplemental Health |
| `dim_broker` | broker or consultant firm | National Consultant / Regional / Local / Direct |
| `dim_account_manager` | account manager | segment team + region |
| `sec_client_group_map` | client × security group | AtScale row-security dataset |
| `fact_client_month` | client × product × month-end | `members`/`subscribers` are **semi-additive**. Revenue, claims and `member_months` are additive |
| `fact_renewal` | client × renewal (plan-year anniversary) | outcome, reason, rate action, prior-12-month experience, escalations |
| `fact_renewal_product` | renewal × product | Retained / Added / Dropped / Terminated |
| `fact_service_case` | service case | category, priority, escalation, onshore/offshore handling, resolution days, CSAT |

**Measure semantics for the model:**
- **Retention rate** = `SUM(retained_count) / SUM(renewal_count)`.
- **Loss ratio (MLR)** = `SUM(insured_claims) / SUM(premium_revenue)`. Filter to insured clients for client-level loss ratios.
- **Concession** = `AVG(proposed_increase_pct) − AVG(final_increase_pct)`.
- **PMPM revenue** = `SUM(total_revenue) / SUM(member_months)`.
- **Distinct clients** = `COUNT(DISTINCT client_id)`.
- `prior_12m_loss_ratio`, the `*_pct` columns, `days_to_resolve` and `csat_score` are **non-additive**. Average them, or recompute them from their components.
- **Revenue basis.** Insured clients (Guaranteed Cost and Level Funded) generate `premium_revenue` and `insured_claims`.
  ASO clients generate `admin_fee_revenue` and `client_funded_claims`. Stop-loss and supplemental premiums count as insured revenue for any funding type.

## Aggregate shape (seed 42)

- 715 clients: 374 Select, 254 Middle Market, 87 National Accounts. 462 are active at window end and 253 terminated in window. **374 (52%) restrict offshore access.**
- Funding: 342 ASO, 201 Guaranteed Cost, 172 Level Funded.
- About $16.7B total revenue over the window and $5.62B in 2025. 4.42M medical members at 2026-09.
- 1,608 renewals, of which 253 were lost, representing about $1.59B of prior-12-month revenue.
- 72,370 service cases. 1,630 are escalated and 336 are still open at window end.
- Row counts: `fact_client_month` 75,204 · `fact_renewal_product` 6,713 · `sec_client_group_map` 1,056 · `dim_date` 1,096.

## Known limitations

- Single currency (USD), no FX, no taxes or fees beyond the admin fees.
- Monthly grain only. No claim-line, member-level or Rx-script detail. GLP-1 is a pre-aggregated claims column.
- Membership and revenue are illustrative and are not calibrated to any carrier's reported financials. ASO admin fees and
  insured premiums are flat PMPMs per product.
- The broker of record is static per client.
- Renewal year 2023 holds only October–December renewals and 2026 runs through September. 2024 and 2025 are the complete years.
- Rate actions are one blended increase per client renewal. There is no product-level pricing.
- Forward-looking renewal pipeline and revenue at risk are **out of scope**. No pending renewals beyond 2026-09 are modelled.
- PK constraints are informational (NOT ENFORCED) on Unity Catalog. FKs are documented, not declared.
