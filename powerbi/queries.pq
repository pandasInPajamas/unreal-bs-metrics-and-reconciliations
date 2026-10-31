// One block per query. For each: New Source > Blank Query > Advanced Editor,
// select everything, paste ONE block (from 'let' to the last 'Typed'), OK, then rename the query
// to the name in the ==== line. Money with 2 decimals = Fixed decimal (Currency.Type);
// line-level amounts with 6 decimals = Decimal number, so totals still tie to the cent.

// ==== dim_date ====
let
    Source = fnLoadCsv("dim_date.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"date", type date},
        {"month_start", type date},
        {"year", Int64.Type},
        {"month_num", Int64.Type},
        {"month_label", type text},
        {"year_month", type text},
        {"quarter_label", type text},
        {"weekday", type text},
        {"is_weekday", type logical},
        {"is_month_end", type logical}
    }, "en-US")
in
    Typed

// ==== dim_customer ====
let
    Source = fnLoadCsv("dim_customer.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"customer_id", type text},
        {"customer_name", type text},
        {"currency", type text},
        {"market", type text},
        {"country", type text},
        {"created_date", type date},
        {"first_arr_month", type date},
        {"is_story_customer", type logical}
    }, "en-US")
in
    Typed

// ==== dim_gl_account ====
let
    Source = fnLoadCsv("dim_gl_account.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"account_id", type text},
        {"account_number", type text},
        {"account_name", type text},
        {"classification", type text},
        {"account_type", type text},
        {"statement", type text},
        {"walk_order", Int64.Type},
        {"walk", type text},
        {"walk_step", type text},
        {"relationship_to_arr", type text}
    }, "en-US")
in
    Typed

// ==== dim_recon_check ====
let
    Source = fnLoadCsv("dim_recon_check.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"check_order", Int64.Type},
        {"check_name", type text},
        {"gl_account", type text}
    }, "en-US")
in
    Typed

// ==== dim_root_cause ====
let
    Source = fnLoadCsv("dim_root_cause.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"rc_id", type text},
        {"category", type text},
        {"title", type text},
        {"from_date", type date},
        {"to_date", type date},
        {"what_happened", type text},
        {"prevention", type text},
        {"status", type text},
        {"correction_memo", type text},
        {"dr_account", type text},
        {"cr_account", type text}
    }, "en-US")
in
    Typed

// ==== dim_walk_step ====
let
    Source = fnLoadCsv("dim_walk_step.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"step_key", Int64.Type},
        {"walk", Int64.Type},
        {"step_order", Int64.Type},
        {"step", type text}
    }, "en-US")
in
    Typed

// ==== fact_arr_snapshot ====
let
    Source = fnLoadCsv("fact_arr_snapshot.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"snapshot_month", type date},
        {"subscription_id", type text},
        {"customer_id", type text},
        {"plan", type text},
        {"billing_interval", type text},
        {"currency", type text},
        {"arr_local", type number},
        {"fx_rate_to_usd", type number},
        {"arr_usd", type number},
        {"mrr_usd", type number}
    }, "en-US")
in
    Typed

// ==== fact_arr_movement ====
let
    Source = fnLoadCsv("fact_arr_movement.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"snapshot_month", type date},
        {"customer_id", type text},
        {"movement_type", type text},
        {"opening_arr_usd", type number},
        {"movement_usd", type number},
        {"fx_usd", type number},
        {"closing_arr_usd", type number}
    }, "en-US")
in
    Typed

// ==== fact_gl_line ====
let
    Source = fnLoadCsv("fact_gl_line.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"posting_date", type date},
        {"source", type text},
        {"doc_number", type text},
        {"source_id", type text},
        {"line_index", Int64.Type},
        {"account_id", type text},
        {"posting_type", type text},
        {"signed_amount_usd", Currency.Type},
        {"description", type text}
    }, "en-US")
in
    Typed

// ==== fact_recon_daily ====
let
    Source = fnLoadCsv("fact_recon_daily.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"txn_date", type date},
        {"check_name", type text},
        {"stripe_usd", Currency.Type},
        {"books_usd", Currency.Type},
        {"diff_usd", Currency.Type},
        {"ties", type logical}
    }, "en-US")
in
    Typed

// ==== fact_recon_monthly ====
let
    Source = fnLoadCsv("fact_recon_monthly.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"month_check_key", type text},
        {"month", type date},
        {"check_name", type text},
        {"diff_usd", Currency.Type},
        {"status", type text},
        {"rc_ids", type text}
    }, "en-US")
in
    Typed

// ==== fact_recon_exception ====
let
    Source = fnLoadCsv("fact_recon_exception.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"rc_id", type text},
        {"txn_date", type date},
        {"check_name", type text},
        {"stripe_usd", Currency.Type},
        {"books_usd", Currency.Type},
        {"diff_usd", Currency.Type},
        {"evidence", type text}
    }, "en-US")
in
    Typed

// ==== fact_correcting_entry ====
let
    Source = fnLoadCsv("fact_correcting_entry.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"line_id", Int64.Type},
        {"rc_id", type text},
        {"entry_date", type date},
        {"memo", type text},
        {"account_name", type text},
        {"debit_usd", Currency.Type},
        {"credit_usd", Currency.Type}
    }, "en-US")
in
    Typed

// ==== fact_walk_line ====
let
    Source = fnLoadCsv("fact_walk_line.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"month", type date},
        {"step_key", Int64.Type},
        {"gl_account", type text},
        {"recon_check", type text},
        {"row_type", type text},
        {"customer_id", type text},
        {"source_id", type text},
        {"amount_usd", type number},
        {"reason", type text},
        {"calculation", type text},
        {"rc_id", type text}
    }, "en-US")
in
    Typed

// ==== bridge_recon_month_root_cause ====
let
    Source = fnLoadCsv("bridge_recon_month_root_cause.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"month_check_key", type text},
        {"month", type date},
        {"check_name", type text},
        {"rc_id", type text}
    }, "en-US")
in
    Typed

// ==== bridge_root_cause_check ====
let
    Source = fnLoadCsv("bridge_root_cause_check.csv"),
    Typed = Table.TransformColumnTypes(Source, {
        {"rc_id", type text},
        {"check_name", type text}
    }, "en-US")
in
    Typed
