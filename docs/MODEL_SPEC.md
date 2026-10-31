# Unreal B.S. — Power BI model spec (working notes)

Synthetic data. 24 months, Oct 2024 – Sep 2026. Every CSV in `data/` comes from
`warehouse/01_build_mart.sql` + `warehouse/02_export_star.sql` against the Postgres demo DB.
All money is **USD**. Line-level amounts keep 6 decimals on purpose: round in the visual, not in the data,
or the walks stop tying to the cent.

---

## Tables

### Dimensions
| Table | Key | Grain / notes |
|---|---|---|
| `dim_date` | `date` | One row per day, 2024-10-01 → 2026-10-31. Has `month_start`, `month_label`, `year_month`, `is_month_end`. Mark as date table. Monthly facts join on the 1st of the month. |
| `dim_customer` | `customer_id` | 2,075 customers. `market` (US / UK / Eurozone), `currency`, `first_arr_month`, `is_story_customer` (the 13 hand-built scenarios). |
| `dim_gl_account` | `account_id` | 7 QuickBooks accounts. `account_name` is also unique (correcting entries join on it). Walk mapping columns from the account map. |
| `dim_recon_check` | `check_name` | 8 checks. `check_order` for sorting. Deferred Revenue is checked twice (billed, and month-end balance). |
| `dim_root_cause` | `rc_id` | 5 rows: RC-01…RC-04 are errors, RC-00 is timing (not an error). |
| `dim_walk_step` | `step_key` | 12 steps. `step_key = walk × 10 + step_order`. Sort `step` by `step_key`. |

### Facts
| Table | Grain | Joins to |
|---|---|---|
| `fact_arr_snapshot` | subscription × month | date (`snapshot_month`), customer |
| `fact_arr_movement` | customer × month | date (`snapshot_month`), customer |
| `fact_gl_line` | GL posting line (journal entries + deposits, signed: debit +, credit −) | date (`posting_date`), gl_account |
| `fact_recon_daily` | check × day | date (`txn_date`), recon_check |
| `fact_recon_monthly` | check × month (179 rows) | date (`month`), recon_check; bridge via `month_check_key` |
| `fact_recon_exception` | one row per exception (6) | date, recon_check, root_cause |
| `fact_correcting_entry` | correcting journal line (22) | date (`entry_date`), gl_account (by `account_name`), root_cause |
| `fact_walk_line` | the line detail behind both walks (32,679 rows) | date (`month`), customer, walk_step, root_cause |

### Bridges (many-to-many)
| Table | Purpose |
|---|---|
| `bridge_recon_month_root_cause` | month-check ↔ root cause (12 rows). Join `fact_recon_monthly[month_check_key]` 1→* bridge, bridge *→1 `dim_root_cause`. |
| `bridge_root_cause_check` | which checks each root cause can hit (8 rows). |

## Relationships (all single-direction, one-to-many unless noted)
- `dim_date[date]` → every fact's date column (8 relationships).
- `dim_customer[customer_id]` → `fact_arr_snapshot`, `fact_arr_movement`, `fact_walk_line`.
- `dim_gl_account[account_id]` → `fact_gl_line`; `dim_gl_account[account_name]` → `fact_correcting_entry[account_name]` (make one of the two keys inactive or use a second role-play copy, your call).
- `dim_recon_check[check_name]` → `fact_recon_daily`, `fact_recon_monthly`, `fact_recon_exception`.
- `dim_root_cause[rc_id]` → `fact_recon_exception`, `fact_correcting_entry`, `fact_walk_line`, `bridge_recon_month_root_cause`.
- `fact_recon_monthly[month_check_key]` → `bridge_recon_month_root_cause[month_check_key]`. Decide on bidirectional vs. `CROSSFILTER` in the measure. Measure-level is cleaner for the story.
- `dim_walk_step[step_key]` → `fact_walk_line`.

`fact_walk_line[gl_account]` and `[recon_check]` are labels, not keys: the first walk step is "— (metric)".

---

## Measure list (logic only; the DAX and the descriptions are yours)

**ARR / MRR** (semi-additive: snapshot at the last month in context, never summed across months)
- MRR, ARR, Active customers (ARR > 0), ARR by market
- Opening ARR, New, Expansion, Contraction, Churn, Reactivation, FX, Closing ARR (bridge)
- Optional: NRR (trailing 12m), Quick ratio

**GL**
- GL Revenue = −(signed amount on Revenue accounts) for the period
- GL Deposits = signed amount on Operating Checking
- Deferred Revenue balance = running signed balance on 2300 at month end

**Walks**
- Walk amount (sum of `amount_usd`), Walk 1 end (= sum of all Walk 1 steps), Walk 2 end (= GL Revenue + Walk 2 steps)
- Walk 1 ties? (|Walk 1 end − GL Revenue| < 0.005), Walk 2 ties? (|Walk 2 end − GL Deposits| < 0.005)

**Recon**
- Month-checks, Month-checks that tie, Month-checks that don't, Tie rate
- Months with a break, Absolute difference, Exceptions, Root causes (errors only, excludes RC-00)
- Correcting debits, Correcting credits, Entries balance? (Dr = Cr)

---

## Test oracle: build the measure, then check it matches

| Check | Expected |
|---|---|
| MRR, Sep 2026 | **51,952.58** |
| ARR, Sep 2026 | **623,430.92** (not MRR × 12 = 623,430.96: MRR is rounded per row. Pick a definition and say so.) |
| Active customers, Sep 2026 | **971** |
| MRR by market, Sep 2026 | US 30,908.00 · UK 10,155.24 · Eurozone 10,889.34 |
| ARR bridge, Sep 2026 | Open 583,695.19 · New +46,504.39 · Expansion +7,424.08 · Contraction −2,724.10 · Churn −13,864.86 · FX +2,396.22 · Close 623,430.92 |
| Walk 1, Sep 2026 | MRR 51,952.58 · monthly +168.48 · annual −430.23 · FX −191.28 · top-ups +2,828.24 · refunds −76.21 = **GL Revenue 54,251.58** |
| Walk 2, Sep 2026 | GL Revenue 54,251.58 · deferred +4,498.47 · fees −2,162.95 · in transit +4,054.95 = **Deposits 60,642.05** |
| Both walks | Tie to the GL in **all 24 months** |
| Month-checks | **179** total · **167** tie · **12** don't · in **9** of 24 months |
| Exceptions / root causes | **6** exceptions · **4** root causes (+ RC-00 timing) |
| Correcting entries | Dr = Cr = **4,340.72** (22 lines) |
| GL lines | Sum of `signed_amount_usd` over everything = **0.00** |

## README outline (for GitHub; you write it)
1. The question (does it tie?)
2. The business (fictional, synthetic, generated by `generate.py`)
3. Model diagram + table list
4. Measure dictionary (definitions in your words, same text as the measure descriptions)
5. The four root causes, written up as a mini case study
6. How to open it (PBIP + CSVs, no credentials)
7. Credit: a Sensaxis project
