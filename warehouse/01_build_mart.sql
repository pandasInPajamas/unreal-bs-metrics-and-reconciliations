drop schema if exists mart cascade; create schema mart;

create table mart.arr_snapshot_monthly as
-- arr_snapshot_monthly
-- One row per subscription per month-end snapshot, with the ARR in force at that moment.
-- ARR definition v1: trials excluded; past_due included until ended_at; cancellations leave at ended_at;
-- annual = contracted price, monthly x 12; top-ups and prorations never count; FX at the month-end rate.

with months as (
  -- 1. one snapshot per month: the last second of the month
  select
    m::date                                                   as snapshot_month,
    (m + interval '1 month' - interval '1 second')            as snapshot_at,
    (m + interval '1 month' - interval '1 day')::date         as snapshot_date
  from generate_series('2024-10-01'::date, '2026-09-01'::date, interval '1 month') as m
),

lines as (
  -- 2. recurring subscription lines that actually charged something (no trials, no proration credits, no top-ups)
  select
    il.subscription_id,
    il.period_start,
    il.period_end,
    p.unit_amount,
    p.recurring_interval,
    pr.name                                                   as plan
  from stripe.invoice_line_item il
  join stripe.price   p  on p.id  = il.price_id
  join stripe.product pr on pr.id = p.product_id
  where il.type = 'subscription'
    and il.amount > 0
),

in_force as (
  -- 3. the line covering each snapshot; if a mid-period upgrade overlaps the cycle line, the latest one wins
  select
    m.snapshot_month,
    m.snapshot_at,
    m.snapshot_date,
    l.*,
    row_number() over (
      partition by l.subscription_id, m.snapshot_month
      order by l.period_start desc
    ) as rn
  from months m
  join lines l
    on l.period_start <= m.snapshot_at
   and l.period_end   >  m.snapshot_at
)

-- 4. apply the lifecycle rules, convert to USD
select
  f.snapshot_month,
  f.subscription_id,
  s.customer_id,
  c.currency,
  case c.currency when 'gbp' then 'UK' when 'usd' then 'US' when 'eur' then 'Eurozone' end
                                                              as market,   -- set by billing currency
  f.plan,
  f.recurring_interval                                        as billing_interval,
  f.unit_amount / 100.0
    * case f.recurring_interval when 'month' then 12 else 1 end as arr_local,
  fx.usd_rate                                                 as fx_rate,
  f.unit_amount / 100.0
    * case f.recurring_interval when 'month' then 12 else 1 end
    * fx.usd_rate                                             as arr_usd,  -- unrounded; format in Metabase
  f.unit_amount / 100.0
    * case f.recurring_interval when 'month' then 12 else 1 end
    * fx.usd_rate / 12                                        as mrr_usd
from in_force f
join stripe.subscription_history s
  on s.id = f.subscription_id
 and s._fivetran_active                                       -- current state of the subscription
join stripe.customer c
  on c.id = s.customer_id
join stripe._fx_daily fx
  on fx.currency = c.currency
 and fx.date     = f.snapshot_date
where f.rn = 1
  and (s.trial_end is null or s.trial_end <= f.snapshot_at)   -- trials don't count
  and (s.ended_at  is null or s.ended_at  >  f.snapshot_at)   -- still subscribed (past_due included)
;

create table mart.arr_movements_monthly as
-- arr_movements_monthly
-- One row per customer per month they had ARR at the start or the end of the month.
-- Classifies each customer's change in ARR into exactly one bridge bucket, plus the FX effect.
-- Movements are in local currency, converted at this month's rate; FX = opening ARR x (rate now - rate last month).
-- opening + new + reactivation + expansion + contraction + churn + fx = closing, to the cent.

with snap as (
  -- ARR per customer per month, in local currency (from the ARR snapshot model)
  select snapshot_month, customer_id, currency, sum(arr_local) as arr_local
  from mart.arr_snapshot_monthly
  group by 1, 2, 3
),

customers as (
  select customer_id, currency, min(snapshot_month) as first_arr_month
  from snap
  group by 1, 2
),

rates as (
  -- month-end USD rate for each currency
  select date_trunc('month', fx.date)::date as snapshot_month, fx.currency, fx.usd_rate
  from stripe._fx_daily fx
  where fx.date = (date_trunc('month', fx.date) + interval '1 month' - interval '1 day')::date
),

grid as (
  -- every customer x every month from their first ARR month on, with zeros filled in
  select r.snapshot_month, c.customer_id, c.currency, c.first_arr_month,
         coalesce(s.arr_local, 0) as closing_local,
         r.usd_rate               as rate_now
  from customers c
  join rates r
    on r.currency = c.currency
   and r.snapshot_month >= c.first_arr_month
   and r.snapshot_month <= '2026-09-01'
  left join snap s
    on s.customer_id = c.customer_id
   and s.snapshot_month = r.snapshot_month
),

with_prev as (
  select g.*,
    coalesce(lag(closing_local) over w, 0)      as opening_local,
    coalesce(lag(rate_now)      over w, rate_now) as rate_prev
  from grid g
  window w as (partition by customer_id order by snapshot_month)
)

select
  snapshot_month,
  customer_id,
  currency,
  case currency when 'gbp' then 'UK' when 'usd' then 'US' when 'eur' then 'Eurozone' end
                                                        as market,   -- set by billing currency
  case
    when opening_local = 0 and closing_local > 0 and snapshot_month = first_arr_month then 'New'
    when opening_local = 0 and closing_local > 0  then 'Reactivation'
    when opening_local > 0 and closing_local = 0  then 'Churn'
    when closing_local > opening_local            then 'Expansion'
    when closing_local < opening_local            then 'Contraction'
    else 'No change'
  end                                                   as movement_type,
  opening_local * rate_prev                             as opening_usd,
  (closing_local - opening_local) * rate_now            as movement_usd,
  opening_local * (rate_now - rate_prev)                as fx_usd,
  closing_local * rate_now                              as closing_usd,
  opening_local,
  closing_local
from with_prev
where opening_local > 0 or closing_local > 0
;

create table mart.root_cause_register as
-- root_cause_register
-- The issues log: one row per root cause per check it affects. Written by hand after investigation,
-- the way an accounting team keeps one. Every break on the recon tab is matched to a row here by
-- check and date range; a break with no match shows as "Unassigned".
-- Turn into a model: "Root cause register".

select * from (values
  -- rc_id,  category,                 title,                                                   check_name,                              from_date,    to_date,      what_happened,                                                                                                   prevention,                                                        status,                    correction_memo,                                       dr_account,             cr_account,           amount_sign, catch_up_releases, known_amount_usd
  ('RC-01', 'Sync logic',             'Voided invoice posted as revenue',                       'Stripe Clearing (net of fees)',         '2025-05-28', '2025-05-28', 'The Stripe sync posted invoice UBS-001340 when it was finalized; it was voided 9 days later with no successful charge.', 'Sync skips invoices that are void at posting time; daily clearing check.', 'Correction proposed', null,                                                    null,                   null,                 null::int,   false,             null::numeric),
  ('RC-01', 'Sync logic',             'Voided invoice posted as revenue',                       'Subscription Revenue',                  '2025-05-28', '2025-05-28', 'The Stripe sync posted invoice UBS-001340 when it was finalized; it was voided 9 days later with no successful charge.', 'Sync skips invoices that are void at posting time; daily clearing check.', 'Correction proposed', 'Reverse revenue for voided invoice UBS-001340',          'Subscription Revenue', 'Stripe Clearing',     1,          false,             null),
  ('RC-02', 'Sync logic',             'Refund never reached the books',                         'Refunds',                               '2025-07-20', '2025-07-20', 'Stripe refunded $49.00 to Winifred Castellanos; the sync dropped the refund event.',                                   'Alert on any Stripe refund with no matching booking within 1 day.',   'Correction proposed', 'Book missing Stripe refund (Winifred Castellanos)',     'Refunds & Allowances', 'Stripe Clearing',    -1,          false,             null),
  ('RC-03', 'Mapping rule',           'Annual-plan upgrade charge booked to revenue',           'Subscription Revenue',                  '2025-08-20', '2025-08-20', 'Ingrid Solberg''s mid-term annual upgrade was mapped to Subscription Revenue instead of Deferred Revenue.',          'Map proration lines by billing interval, not by invoice type.',       'Correction proposed', 'Reclassify Ingrid Solberg''s annual upgrade to deferred', 'Subscription Revenue', 'Deferred Revenue',    1,          true,              null),
  ('RC-03', 'Mapping rule',           'Annual-plan upgrade charge booked to revenue',           'Deferred Revenue (billed)',             '2025-08-20', '2025-08-20', 'Ingrid Solberg''s mid-term annual upgrade was mapped to Subscription Revenue instead of Deferred Revenue.',          'Map proration lines by billing interval, not by invoice type.',       'Correction proposed', null,                                                    null,                   null,                 null,        false,             null),
  ('RC-03', 'Mapping rule',           'Annual-plan upgrade charge booked to revenue',           'Deferred Revenue balance (month-end)',  '2025-08-01', '2026-01-31', 'Ingrid Solberg''s mid-term annual upgrade was mapped to Subscription Revenue instead of Deferred Revenue.',          'Map proration lines by billing interval, not by invoice type.',       'Correction proposed', null,                                                    null,                   null,                 null,        false,             null),
  ('RC-04', 'Manual entry',           'Payout deposit entered twice',                           'Payouts → Deposits',                    '2026-03-18', '2026-03-18', 'Payout po_QbvLDkPkTaC22Q0k8VisA75N was recorded as DEP00357, then entered again the next day as DEP00358.',        'Block deposits whose payout ID is already in the books.',              'Correction proposed', 'Reverse duplicate deposit DEP00358',                     'Stripe Clearing',      'Operating Checking',  1,          false,             null),
  ('RC-00', 'Timing (not an error)',  'Annual plan paid after its service started',             'Deferred Revenue balance (month-end)',  '2025-10-01', '2025-10-31', 'A $190 annual plan started Oct 29, 2025; the payment cleared Nov 1. The books post deferred revenue when the charge settles, so it is not in the Oct month-end balance. The recon follows the same rule, so no break.', 'None needed; known reconciling item.', 'Explained, no entry', null, null, null, null, false, 190.00)
) as r(rc_id, category, title, check_name, from_date, to_date, what_happened, prevention, status,
       correction_memo, dr_account, cr_account, amount_sign, catch_up_releases, known_amount_usd)
;

create table mart.recon_daily as
-- recon_daily
-- One row per day per check: what Stripe says vs what QuickBooks booked, in USD.
-- Stripe is the source of truth; QuickBooks posts one summary journal entry per day (STRIPE-YYYYMMDD)
-- and one deposit per payout. A check ties when the difference is under half a cent.

with charge_lines as (
  -- each successful charge's settled USD, allocated across its invoice lines (last line absorbs rounding)
  select
    bt.created::date                                              as txn_date,
    bt.amount                                                     as charge_usd_cents,
    bt.fee, bt.net,
    i.billing_reason,
    il.amount                                                     as line_local_cents,
    i.total                                                       as invoice_local_cents,
    p.recurring_interval,
    row_number() over (partition by bt.id order by il.amount, il.id)  as line_no,
    count(*)     over (partition by bt.id)                        as line_count,
    bt.id                                                         as bt_id
  from stripe.balance_transaction bt
  join stripe.charge  c  on c.id  = bt.source
  join stripe.invoice i  on i.id  = c.invoice_id
  join stripe.invoice_line_item il on il.invoice_id = i.id
  left join stripe.price p on p.id = il.price_id
  where bt.type = 'charge'
),
allocated as (
  select *,
    case when line_no < line_count
         then round(charge_usd_cents::numeric * line_local_cents / invoice_local_cents)
    end as usd_cents_rounded
  from charge_lines
),
allocated2 as (
  select a.*,
    coalesce(usd_cents_rounded,
             charge_usd_cents - coalesce(sum(usd_cents_rounded) over (partition by bt_id), 0)) as line_usd_cents,
    case when billing_reason = 'manual'     then 'Top-up Revenue'
         when recurring_interval = 'year'   then 'Deferred Revenue (billed)'
         else                                    'Subscription Revenue' end      as account
  from allocated a
),
stripe_daily as (
  select txn_date, account as check_name, sum(line_usd_cents) / 100.0 as stripe_usd
  from allocated2 group by 1, 2
  union all
  select txn_date, 'Stripe Clearing (net of fees)', sum(net) / 100.0
  from (select distinct bt_id, txn_date, net from allocated2) x group by 1
  union all
  select txn_date, 'Merchant Fees', sum(fee) / 100.0
  from (select distinct bt_id, txn_date, fee from allocated2) x group by 1
  union all
  select created::date, 'Refunds', -sum(amount) / 100.0
  from stripe.balance_transaction where type = 'refund' group by 1
  union all
  select arrival_date::date, 'Payouts → Deposits', sum(amount) / 100.0
  from stripe.payout group by 1
),
books_daily as (
  select j.transaction_date as txn_date,
    case
      when a.name = 'Stripe Clearing'      and l.posting_type = 'Debit'  then 'Stripe Clearing (net of fees)'
      when a.name = 'Merchant Fees'                                        then 'Merchant Fees'
      when a.name = 'Subscription Revenue'                                 then 'Subscription Revenue'
      when a.name = 'Deferred Revenue'                                     then 'Deferred Revenue (billed)'
      when a.name = 'Top-up Revenue'                                       then 'Top-up Revenue'
      when a.name = 'Refunds & Allowances'                                 then 'Refunds'
    end as check_name,
    sum(l.amount) as books_usd
  from quickbooks.journal_entry j
  join quickbooks.journal_entry_line l on l.journal_entry_id = j.id
  join quickbooks.account a on a.id = l.account_id
  where j.doc_number like 'STRIPE-%'
    and not j._fivetran_deleted
  group by 1, 2
  union all
  select transaction_date, 'Payouts → Deposits', sum(total_amount)
  from quickbooks.deposit
  where private_note like 'Stripe payout po_%' and not _fivetran_deleted
  group by 1
),
joined as (
  select
    coalesce(s.txn_date, b.txn_date)                       as txn_date,
    coalesce(s.check_name, b.check_name)                   as check_name,
    coalesce(s.stripe_usd, 0)                              as stripe_usd,
    coalesce(b.books_usd, 0)                               as books_usd
  from stripe_daily s
  full join books_daily b
    on b.txn_date = s.txn_date and b.check_name = s.check_name
  where coalesce(s.check_name, b.check_name) is not null
)
select
  txn_date,
  date_trunc('month', txn_date)::date                      as txn_month,
  check_name,
  case check_name
    when 'Stripe Clearing (net of fees)' then 1
    when 'Merchant Fees'                 then 2
    when 'Subscription Revenue'          then 3
    when 'Deferred Revenue (billed)'     then 4
    when 'Top-up Revenue'                then 5
    when 'Refunds'                       then 6
    when 'Payouts → Deposits'            then 7
  end                                                      as check_order,
  stripe_usd,
  books_usd,
  books_usd - stripe_usd                                   as diff_usd,
  abs(books_usd - stripe_usd) < 0.005                      as ties
from joined
where txn_date <= '2026-09-30'
;

create table mart.recon_status_monthly as
-- recon_status_monthly
-- One row per month per check: does it tie? Seven daily checks rolled up to the month,
-- plus the month-end Deferred Revenue balance check, the account behind each check, and the root cause(s)
-- from the register. Swap the IDs: "Recon (daily)" and "Root cause register" models.

with reg as (
  select * from mart.root_cause_register
),
daily as (
  select d.txn_month as month, d.check_name, d.check_order,
         sum(d.diff_usd) as diff_usd,
         count(*) filter (where not d.ties) as days_broken,
         string_agg(distinct coalesce(r.rc_id, 'Unassigned'), ', ') filter (where not d.ties) as rc_ids
  from mart.recon_daily d
  left join reg r
    on not d.ties
   and r.check_name = d.check_name
   and d.txn_date between r.from_date::date and r.to_date::date
  group by 1, 2, 3
),
deferred as (
  -- month-end Deferred Revenue: books vs what Stripe's annual-plan charges say it should be
  with lines as (
    select bt.id as bt_id, bt.created as charged_at, bt.amount as charge_usd_cents, il.amount as line_local_cents, i.total as invoice_local_cents,
      il.period_start, il.period_end, p.recurring_interval, i.billing_reason,
      row_number() over (partition by bt.id order by il.amount, il.id) as line_no,
      count(*)     over (partition by bt.id)                          as line_count
    from stripe.balance_transaction bt
    join stripe.charge  c  on c.id  = bt.source
    join stripe.invoice i  on i.id  = c.invoice_id
    join stripe.invoice_line_item il on il.invoice_id = i.id
    left join stripe.price p on p.id = il.price_id
    where bt.type = 'charge'
  ),
  alloc as (
    select *, case when line_no < line_count
                   then round(charge_usd_cents::numeric * line_local_cents / invoice_local_cents) end as r
    from lines
  ),
  contracts as (
    select period_start, period_end, charged_at,
      coalesce(r, charge_usd_cents - coalesce(sum(r) over (partition by bt_id), 0)) as usd_cents
    from alloc where recurring_interval = 'year' and billing_reason <> 'manual'
  ),
  months as (
    select m::date as month, m + interval '1 month' as next_month_start,
           m + interval '1 month' - interval '1 second' as snapshot_at
    from generate_series('2024-10-01'::timestamp, '2026-09-01'::timestamp, interval '1 month') m
  ),
  truth as (
    select mo.month,
      sum(case when c.charged_at <= mo.snapshot_at then c.usd_cents else 0 end - round(c.usd_cents
            * floor(extract(epoch from (least(mo.next_month_start, c.period_end) - c.period_start)) / 86400)
            / floor(extract(epoch from (c.period_end - c.period_start)) / 86400))) / 100.0 as should_be_usd
    from months mo join contracts c on c.period_start <= mo.snapshot_at
    group by 1
  ),
  books as (
    select mo.month, sum(case l.posting_type when 'Credit' then l.amount else -l.amount end) as books_usd
    from months mo
    join quickbooks.journal_entry j on j.transaction_date < mo.next_month_start and not j._fivetran_deleted
    join quickbooks.journal_entry_line l on l.journal_entry_id = j.id
    join quickbooks.account a on a.id = l.account_id and a.name = 'Deferred Revenue'
    group by 1
  )
  select t.month, 'Deferred Revenue balance (month-end)' as check_name, 8 as check_order,
         coalesce(b.books_usd, 0) - t.should_be_usd as diff_usd,
         case when abs(coalesce(b.books_usd, 0) - t.should_be_usd) < 0.005 then 0 else 1 end as days_broken
  from truth t left join books b using (month)
),
deferred_rc as (
  select d.*,
    case when d.days_broken > 0 then
      coalesce((select string_agg(distinct r.rc_id, ', ') from reg r
                where r.check_name = d.check_name and r.category <> 'Timing (not an error)'
                  and d.month between date_trunc('month', r.from_date::date) and r.to_date::date), 'Unassigned')
    end as rc_ids
  from deferred d
)
select month, check_name, check_order,
  case check_order
    when 1 then 'Stripe Clearing'      when 2 then 'Merchant Fees'
    when 3 then 'Subscription Revenue' when 4 then 'Deferred Revenue'
    when 5 then 'Top-up Revenue'       when 6 then 'Refunds & Allowances'
    when 7 then 'Operating Checking'   when 8 then 'Deferred Revenue'
  end as account,
  diff_usd,
  case when days_broken = 0 then 'Ties' else 'Does not tie' end as status,
  rc_ids
from (select * from daily union all select * from deferred_rc) x
order by month, check_order
;

create table mart.recon_exceptions as
-- recon_exceptions
-- Every daily break from the recon model, matched to its root cause in the register, with the evidence.
-- Swap the IDs: "Recon (daily)" and "Root cause register" models. Turn into a model: "Recon exceptions".

with reg as (
  select * from mart.root_cause_register
),
breaks as (
  select * from mart.recon_daily where not ties
),
matched as (
  select b.*,
    coalesce(r.rc_id, 'Unassigned')                 as rc_id,
    coalesce(r.category, 'Unassigned')              as rc_category,
    coalesce(r.title, 'Unexplained: investigate')   as rc_title
  from breaks b
  left join reg r
    on r.check_name = b.check_name
   and b.txn_date between r.from_date::date and r.to_date::date
)
select
  m.rc_id,
  m.rc_category,
  m.rc_title,
  m.txn_date,
  m.check_name,
  m.stripe_usd,
  m.books_usd,
  m.diff_usd,
  concat_ws(' | ',
    case m.check_name
      when 'Payouts → Deposits' then (
        select string_agg(x.payout_id || ' deposited ' || x.n || '× (' || x.deps || ')', '; ')
        from (select substr(private_note, 15) as payout_id, count(*) as n,
                     string_agg(id, ', ' order by id) as deps, max(transaction_date) as last_dep
              from quickbooks.deposit where not _fivetran_deleted
              group by 1 having count(*) > 1) x
        where x.last_dep = m.txn_date)
      when 'Refunds' then (
        select string_agg(rf.id || ' ($' || to_char(rf.amount / 100.0, 'FM999,990.00') || ' on charge ' || rf.charge_id || ')', '; ')
        from stripe.refund rf where rf.created::date = m.txn_date)
      else (
        select j.doc_number || ': ' || j.private_note
        from quickbooks.journal_entry j where j.transaction_date = m.txn_date and j.doc_number like 'STRIPE-%')
    end,
    case when m.check_name in ('Stripe Clearing (net of fees)', 'Subscription Revenue') then
      'Void in Stripe: ' || (select string_agg(i.number || ' (' || i.id || ')', '; ')
                             from stripe.invoice i where i.status = 'void' and i.created::date = m.txn_date) end,
    case when m.check_name in ('Subscription Revenue', 'Deferred Revenue (billed)') then
      'Annual upgrades that day: ' || (select string_agg(distinct i.id, '; ')
         from stripe.charge c join stripe.invoice i on i.id = c.invoice_id
         join stripe.invoice_line_item il on il.invoice_id = i.id
         join stripe.price p on p.id = il.price_id
        where c.status = 'succeeded' and c.created::date = m.txn_date
          and p.recurring_interval = 'year' and i.billing_reason = 'subscription_update') end
  ) as evidence
from matched m
order by m.rc_id, m.txn_date, m.check_order
;

create table mart.correcting_entries as
-- correcting_entries
-- The journal entries that would make the books agree with Stripe, one row per entry line (Dr / Cr),
-- each tagged with its root cause. The register says which account to debit and credit; the amounts
-- come from the breaks. Catch-up releases restore the month-end deferred revenue release on a
-- reclassified annual charge.
-- Swap the IDs: "Recon exceptions", "Recon status (monthly)" and "Root cause register" models. Turn into a model: "Correcting entries".

with reg as (
  select * from mart.root_cause_register
),
ex as (
  select * from mart.recon_exceptions
),
primary_entries as (
  -- one entry per root cause, from the break on the check the register names for the amount
  select e.rc_id, r.category, r.title, e.txn_date as entry_date, r.correction_memo as memo,
         r.dr_account, r.cr_account, r.amount_sign * e.diff_usd as amount_usd
  from ex e
  join reg r on r.rc_id = e.rc_id and r.check_name = e.check_name and r.correction_memo is not null
),
deferred as (
  select month, diff_usd, rc_ids,
         diff_usd - coalesce(lag(diff_usd) over (order by month), 0) as change_usd
  from mart.recon_status_monthly
  where check_order = 8
),
catch_up as (
  -- month-end releases on each reclassified annual charge, through the month its balance returns to zero
  select p.rc_id, p.category, p.title,
         (d.month + interval '1 month' - interval '1 day')::date as entry_date,
         'Catch-up release of earned revenue on the reclassified charge' as memo,
         'Deferred Revenue' as dr_account, 'Subscription Revenue' as cr_account,
         case when d.month = date_trunc('month', p.entry_date) then p.amount_usd + d.diff_usd
              else d.change_usd end as amount_usd
  from primary_entries p
  join reg r on r.rc_id = p.rc_id and r.catch_up_releases
  join deferred d
    on d.month >= date_trunc('month', p.entry_date)
   and d.month <= (select (date_trunc('month', max(r2.to_date::date)) + interval '1 month')::date
                   from reg r2 where r2.rc_id = p.rc_id)
),
entries as (
  select * from primary_entries
  union all
  select * from catch_up
)
select rc_id, category, entry_date, memo, account, debit_usd, credit_usd
from (
  select rc_id, category, entry_date, memo, dr_account as account,
         round(amount_usd, 2) as debit_usd, null::numeric as credit_usd, 1 as side
  from entries
  union all
  select rc_id, category, entry_date, memo, cr_account, null, round(amount_usd, 2), 2
  from entries
) x
where abs(coalesce(debit_usd, credit_usd)) >= 0.005
order by rc_id, entry_date, side
;

create table mart.root_causes_summary as
-- root_causes_summary
-- The register, one row per root cause, with how far each one reached:
-- exceptions (daily breaks), month-checks that don't tie, months affected, accounts hit, and the gross error.
-- Swap the IDs: "Root cause register", "Recon exceptions" and "Recon status (monthly)" models. Turn into a model: "Root causes".

with reg as (
  select rc_id, max(category) as category, max(title) as title, max(what_happened) as what_happened,
         max(prevention) as prevention, max(status) as status, max(known_amount_usd) as known_amount_usd
  from mart.root_cause_register
  group by rc_id
),
ex as (
  select rc_id, count(*) as exceptions, max(abs(diff_usd)) as gross_error_usd
  from mart.recon_exceptions
  group by rc_id
),
mc as (
  select trim(rc) as rc_id,
         count(*)                                         as month_checks,
         count(distinct month)                            as months,
         string_agg(distinct account, ', ')               as accounts,
         min(month)                                       as first_month,
         max(month)                                       as last_month
  from mart.recon_status_monthly, unnest(string_to_array(rc_ids, ',')) as rc
  where status = 'Does not tie'
  group by 1
)
select r.rc_id, r.category, r.title,
  coalesce(e.exceptions, 0)                               as exceptions,
  coalesce(m.month_checks, 0)                             as month_checks,
  coalesce(m.months, 0)                                   as months,
  case when m.first_month is null then null
       when m.first_month = m.last_month then to_char(m.first_month, 'Mon YYYY')
       else to_char(m.first_month, 'Mon YYYY') || ' – ' || to_char(m.last_month, 'Mon YYYY') end as months_affected,
  m.accounts,
  coalesce(e.gross_error_usd, r.known_amount_usd)         as amount_usd,
  r.status,
  r.what_happened,
  r.prevention
from reg r
left join ex e using (rc_id)
left join mc m using (rc_id)
order by case when r.category = 'Timing (not an error)' then 1 else 0 end, r.rc_id
;

create table mart.arr_to_cash_detail as
-- arr_to_cash_detail
-- Every row behind the two walks on the "Does it tie?" tab, one row per subscription, charge, refund,
-- payout timing item or correcting-entry line. Add up a month's rows for one step and you get that
-- waterfall bar to the cent.
--   Walk 1, MRR → GL revenue (the P&L):        MRR · monthly plans timing · annual plans timing · FX ·
--                                               top-ups · refunds · revenue book errors          = GL revenue
--   Walk 2, GL revenue → cash (balance sheet):  back out revenue errors · annual billed, not yet earned ·
--                                               merchant fees · payouts in transit · deposit book errors = GL deposits
-- Columns: month, walk, step, GL account, recon check (one of the 8, or "— (metric only)"), row type,
-- customer, source ID, amount, reason, and the calculation in words.
-- Swap ID for your "Correcting entries" model. Model 133 is the ARR snapshot. Turn into a model: "ARR to cash: line detail".

with months as (
  select m::date as month, m as month_start, m + interval '1 month' as next_month_start,
         (m + interval '1 month' - interval '1 day')::date as month_end
  from generate_series('2024-10-01'::timestamp, '2026-09-01'::timestamp, interval '1 month') m
),
rates as materialized (
  -- month-end USD rate per currency (MRR is valued at these)
  select mo.month, fx.currency, fx.usd_rate as rate_me
  from months mo join stripe._fx_daily fx on fx.date = mo.month_end
),
cust as materialized (
  select id as customer_id, name as customer_name, currency from stripe.customer
),

-- ---------- Stripe charges, allocated to invoice lines in settled USD (last line absorbs rounding) ----------
lines as (
  select bt.id as bt_id, bt.source as charge_id, bt.created as charged_at, bt.amount as charge_usd_cents,
         bt.fee as fee_cents, bt.net as net_cents, bt.payout_id,
         i.id as invoice_id, i.number as invoice_number, i.billing_reason, i.customer_id, i.total as invoice_local_cents,
         il.id as line_id, il.subscription_id, il.amount as line_local_cents, il.proration,
         il.period_start, il.period_end, p.recurring_interval,
         row_number() over (partition by bt.id order by il.amount, il.id) as line_no,
         count(*)     over (partition by bt.id)                          as line_count
  from stripe.balance_transaction bt
  join stripe.charge  c  on c.id  = bt.source
  join stripe.invoice i  on i.id  = c.invoice_id
  join stripe.invoice_line_item il on il.invoice_id = i.id
  left join stripe.price p on p.id = il.price_id
  where bt.type = 'charge'
),
alloc as materialized (
  select l.*,
    coalesce(r, charge_usd_cents - coalesce(sum(r) over (partition by bt_id), 0)) as line_usd_cents,
    case when billing_reason = 'manual'   then 'topup'
         when recurring_interval = 'year' then 'annual'
         else 'monthly' end                as line_class
  from (select *, case when line_no < line_count
                       then round(charge_usd_cents::numeric * line_local_cents / invoice_local_cents) end as r
        from lines) l
),

-- ---------- MRR at month-end, per subscription ----------
mrr as materialized (
  select snapshot_month as month, subscription_id, customer_id, currency, plan, billing_interval,
         arr_local / 12 as mrr_local, fx_rate as rate_me, mrr_usd
  from mart.arr_snapshot_monthly
),

-- ---------- monthly plans: billed in the month, per subscription ----------
monthly_billed as materialized (
  select date_trunc('month', charged_at)::date as month, subscription_id, max(customer_id) as customer_id,
         sum(line_usd_cents) / 100.0   as billed_usd,
         sum(line_local_cents) / 100.0 as billed_local,
         bool_or(proration)            as has_proration,
         count(distinct invoice_id)    as invoice_count,
         string_agg(distinct invoice_number, ', ') as invoices
  from alloc where line_class = 'monthly'
  group by 1, 2
),

-- ---------- annual plans: earned in the month, per contract (straight-line by day, cumulative rounding) ----------
contracts as (
  select * from alloc where line_class = 'annual'
),
earned_contract as materialized (
  select mo.month, c.subscription_id, c.customer_id, c.invoice_number, c.line_usd_cents, c.line_local_cents,
         c.period_start, c.period_end,
         floor(extract(epoch from (c.period_end - c.period_start)) / 86400) as term_days,
         floor(extract(epoch from (least(mo.next_month_start, c.period_end) - c.period_start)) / 86400)
           - case when c.period_start >= mo.month_start then 0
                  else floor(extract(epoch from (least(mo.month_start, c.period_end) - c.period_start)) / 86400) end as days_this_month,
         ( round(c.line_usd_cents * floor(extract(epoch from (least(mo.next_month_start, c.period_end) - c.period_start)) / 86400)
                 / floor(extract(epoch from (c.period_end - c.period_start)) / 86400))
         - case when c.period_start >= mo.month_start then 0
                else round(c.line_usd_cents * floor(extract(epoch from (least(mo.month_start, c.period_end) - c.period_start)) / 86400)
                           / floor(extract(epoch from (c.period_end - c.period_start)) / 86400)) end ) / 100.0 as earned_usd,
         ( round(c.line_local_cents * floor(extract(epoch from (least(mo.next_month_start, c.period_end) - c.period_start)) / 86400)
                 / floor(extract(epoch from (c.period_end - c.period_start)) / 86400))
         - case when c.period_start >= mo.month_start then 0
                else round(c.line_local_cents * floor(extract(epoch from (least(mo.month_start, c.period_end) - c.period_start)) / 86400)
                           / floor(extract(epoch from (c.period_end - c.period_start)) / 86400)) end ) / 100.0 as earned_local
  from months mo
  join contracts c on c.period_start < mo.next_month_start and c.period_end > mo.month_start
),
annual_earned as materialized (
  select month, subscription_id, max(customer_id) as customer_id,
         sum(earned_usd) as earned_usd, sum(earned_local) as earned_local,
         count(*) as contracts, max(term_days) as term_days, max(days_this_month) as days_this_month,
         bool_or(period_start >= (month::timestamp)) as started_this_month,
         bool_or(period_end   <  (month::timestamp + interval '1 month')) as ended_this_month,
         string_agg(distinct invoice_number, ', ') as invoices,
         max(line_local_cents) / 100.0 as contract_local
  from earned_contract
  group by 1, 2
),

-- ---------- per subscription: metric vs billed/earned, split into timing and FX ----------
monthly_walk as (
  select coalesce(b.month, m.month) as month, coalesce(b.subscription_id, m.subscription_id) as subscription_id,
         coalesce(b.customer_id, m.customer_id) as customer_id,
         coalesce(b.billed_usd, 0) as billed_usd, coalesce(b.billed_local, 0) as billed_local,
         coalesce(m.mrr_local, 0) as mrr_local, b.has_proration, b.invoice_count, b.invoices
  from monthly_billed b
  full join (select * from mrr where billing_interval = 'month') m
    on m.month = b.month and m.subscription_id = b.subscription_id
),
annual_walk as (
  select coalesce(e.month, m.month) as month, coalesce(e.subscription_id, m.subscription_id) as subscription_id,
         coalesce(e.customer_id, m.customer_id) as customer_id,
         coalesce(e.earned_usd, 0) as earned_usd, coalesce(e.earned_local, 0) as earned_local,
         coalesce(m.mrr_local, 0) as mrr_local, e.contracts, e.term_days, e.days_this_month,
         e.started_this_month, e.ended_this_month, e.invoices, e.contract_local
  from annual_earned e
  full join (select * from mrr where billing_interval = 'year') m
    on m.month = e.month and m.subscription_id = e.subscription_id
),

-- ---------- book errors (from the correcting entries) ----------
fixes as materialized (
  select date_trunc('month', entry_date)::date as month, rc_id, entry_date, memo, account,
         coalesce(credit_usd, 0) - coalesce(debit_usd, 0) as credit_minus_debit
  from mart.correcting_entries
),

-- ---------- payouts in transit: Stripe balance created in one month, paid out in another ----------
bal as materialized (
  select bt.id, bt.type, bt.source, bt.created, bt.net / 100.0 as net_usd, p.id as payout_id, p.arrival_date,
         coalesce(ch.customer_id, rch.customer_id) as customer_id
  from stripe.balance_transaction bt
  left join stripe.payout p   on p.id = bt.payout_id
  left join stripe.charge ch  on bt.type = 'charge' and ch.id = bt.source
  left join stripe.refund rf  on bt.type = 'refund' and rf.id = bt.source
  left join stripe.charge rch on rch.id = rf.charge_id
  where bt.type in ('charge', 'refund')
),

rows as (
  -- ===== Walk 1: MRR → GL revenue =====
  select m.month, 1 as walk, 1 as step_order, 'MRR (ARR tab)' as step, '— (metric)' as gl_account,
         '— (metric only)' as recon_check, 'Contract run-rate' as row_type, m.customer_id,
         m.subscription_id as source_id, m.mrr_usd as amount_usd,
         initcap(m.billing_interval) || 'ly · ' || m.plan as reason,
         upper(m.currency) || ' ' || to_char(m.mrr_local, 'FM999,990.00') || ' a month × ' || to_char(m.rate_me, 'FM0.0000')
           || ' (month-end rate)' as calculation,
         null::text as rc_id
  from mrr m

  union all
  select w.month, 1, 2, 'Monthly plans: billed vs run-rate', 'Subscription Revenue', '— (metric only)', 'Timing',
         w.customer_id, w.subscription_id,
         (w.billed_local - w.mrr_local) * r.rate_me,
         case when w.has_proration                       then 'Proration (plan change mid-cycle)'
              when w.invoice_count > 1                   then 'Two billing cycles fell in this month'
              when w.mrr_local = 0 and w.billed_local > 0 then 'Billed, then left before month-end'
              when w.billed_local = 0 and w.mrr_local > 0 then 'In MRR, not billed this month (past due or billing date)'
              else 'Other' end,
         'Billed ' || to_char(w.billed_local, 'FM999,990.00') || ' − run-rate ' || to_char(w.mrr_local, 'FM999,990.00')
           || ' (' || upper(c.currency) || ') × ' || to_char(r.rate_me, 'FM0.0000') || coalesce(' · ' || w.invoices, ''),
         null
  from monthly_walk w
  join cust c on c.customer_id = w.customer_id
  join rates r on r.month = w.month and r.currency = c.currency
  where w.billed_local <> w.mrr_local

  union all
  select w.month, 1, 3, 'Annual plans: earned vs run-rate', 'Subscription Revenue', '— (metric only)', 'Timing',
         w.customer_id, w.subscription_id,
         (w.earned_local - w.mrr_local) * r.rate_me,
         case when w.contracts > 1                        then 'Plan changed mid-term'
              when w.started_this_month                   then 'Started mid-month'
              when w.ended_this_month                     then 'Term ended mid-month'
              when w.mrr_local = 0 and w.earned_local > 0 then 'Canceled or downgraded; still earning'
              when w.days_this_month = 31                 then '31-day month (earns more than 1/12)'
              when w.days_this_month < 31                 then w.days_this_month || '-day month (earns less than 1/12)'
              else 'Other' end,
         upper(c.currency) || ' ' || to_char(coalesce(w.contract_local, 0), 'FM999,990.00') || ' × '
           || coalesce(w.days_this_month, 0) || '/' || coalesce(w.term_days, 365) || ' earned − '
           || to_char(w.mrr_local, 'FM999,990.00') || ' run-rate, × ' || to_char(r.rate_me, 'FM0.0000')
           || coalesce(' · ' || w.invoices, ''),
         null
  from annual_walk w
  join cust c on c.customer_id = w.customer_id
  join rates r on r.month = w.month and r.currency = c.currency
  where round(w.earned_local, 6) <> round(w.mrr_local, 6)

  union all
  select w.month, 1, 4, 'FX: transaction rate vs month-end rate', 'Subscription Revenue', '— (metric only)', 'FX',
         w.customer_id, w.subscription_id,
         w.billed_usd - w.billed_local * r.rate_me,
         'Monthly plan billed at the rate on the charge date',
         upper(c.currency) || ' ' || to_char(w.billed_local, 'FM999,990.00') || ': settled at $'
           || to_char(w.billed_usd, 'FM999,990.00') || ', valued at month-end ' || to_char(r.rate_me, 'FM0.0000')
           || ' = $' || to_char(w.billed_local * r.rate_me, 'FM999,990.00'),
         null
  from monthly_walk w
  join cust c on c.customer_id = w.customer_id
  join rates r on r.month = w.month and r.currency = c.currency
  where c.currency <> 'usd' and w.billed_local <> 0

  union all
  select w.month, 1, 4, 'FX: transaction rate vs month-end rate', 'Subscription Revenue', '— (metric only)', 'FX',
         w.customer_id, w.subscription_id,
         w.earned_usd - w.earned_local * r.rate_me,
         'Annual plan earned at the rate on the charge date',
         upper(c.currency) || ' ' || to_char(w.earned_local, 'FM999,990.00') || ' earned: booked at $'
           || to_char(w.earned_usd, 'FM999,990.00') || ', valued at month-end ' || to_char(r.rate_me, 'FM0.0000')
           || ' = $' || to_char(w.earned_local * r.rate_me, 'FM999,990.00'),
         null
  from annual_walk w
  join cust c on c.customer_id = w.customer_id
  join rates r on r.month = w.month and r.currency = c.currency
  where w.earned_local <> 0 and round(w.earned_usd - w.earned_local * r.rate_me, 6) <> 0

  union all
  select date_trunc('month', a.charged_at)::date, 1, 5, 'Top-ups (not ARR)', 'Top-up Revenue', 'Top-up Revenue', 'Stripe charge',
         a.customer_id, a.charge_id, a.line_usd_cents / 100.0,
         'Emergency Delegation Pack',
         a.invoice_number || ' · ' || upper(a.currency_code) || ' ' || to_char(a.line_local_cents / 100.0, 'FM999,990.00'),
         null
  from (select alloc.*, c.currency as currency_code from alloc join cust c on c.customer_id = alloc.customer_id) a
  where a.line_class = 'topup'

  union all
  select date_trunc('month', bt.created)::date, 1, 6, 'Refunds', 'Refunds & Allowances', 'Refunds', 'Stripe refund',
         c.customer_id, rf.id, bt.amount / 100.0,
         coalesce(rf.reason, 'Refund'),
         'Refund of charge ' || rf.charge_id || ' · ' || upper(rf.currency) || ' ' || to_char(rf.amount / 100.0, 'FM999,990.00'),
         null
  from stripe.balance_transaction bt
  join stripe.refund rf on rf.id = bt.source
  join stripe.charge c on c.id = rf.charge_id
  where bt.type = 'refund'

  union all
  select f.month, 1, 7, 'Revenue book errors', f.account,
         case f.account when 'Refunds & Allowances' then 'Refunds' else 'Subscription Revenue' end,
         'Correcting entry', null, f.rc_id, -f.credit_minus_debit,
         f.memo, 'The GL is off by this much; the ' || f.rc_id || ' correcting entry dated ' || to_char(f.entry_date, 'DD Mon YYYY') || ' fixes it',
         f.rc_id
  from fixes f
  where f.account in ('Subscription Revenue', 'Top-up Revenue', 'Refunds & Allowances')

  -- ===== Walk 2: GL revenue → cash deposited =====
  union all
  select f.month, 2, 1, 'Back out revenue book errors', f.account,
         case f.account when 'Refunds & Allowances' then 'Refunds' else 'Subscription Revenue' end,
         'Correcting entry', null, f.rc_id, f.credit_minus_debit,
         f.memo, 'Removes the ' || f.rc_id || ' error so the walk continues from what Stripe says', f.rc_id
  from fixes f
  where f.account in ('Subscription Revenue', 'Top-up Revenue', 'Refunds & Allowances')

  union all
  select date_trunc('month', a.charged_at)::date, 2, 2, 'Annual billed, not yet earned', 'Deferred Revenue',
         'Deferred Revenue (billed)', 'Stripe charge', a.customer_id, a.charge_id, a.line_usd_cents / 100.0,
         case when a.line_usd_cents < 0 then 'Credit for the unused part of the old plan' else 'Annual plan billed upfront' end,
         a.invoice_number || ' · service ' || to_char(a.period_start, 'DD Mon YYYY') || ' – ' || to_char(a.period_end, 'DD Mon YYYY'),
         null
  from alloc a where a.line_class = 'annual'

  union all
  select e.month, 2, 2, 'Annual billed, not yet earned', 'Deferred Revenue',
         'Deferred Revenue balance (month-end)', 'Release', e.customer_id, e.subscription_id, -e.earned_usd,
         'Earned this month (already in revenue)',
         e.invoice_number || ': $' || to_char(e.line_usd_cents / 100.0, 'FM999,990.00') || ' × ' || e.days_this_month || '/' || e.term_days,
         null
  from earned_contract e where e.earned_usd <> 0

  union all
  select date_trunc('month', a.charged_at)::date, 2, 3, 'Merchant fees', 'Merchant Fees', 'Merchant Fees', 'Stripe charge',
         a.customer_id, a.charge_id, -a.fee_cents / 100.0,
         case when cu.currency = 'usd' then '2.9% + 30¢' else '3.9% + 30¢ (currency conversion)' end,
         'Fee on $' || to_char(a.charge_usd_cents / 100.0, 'FM999,990.00') || ' charged',
         null
  from (select distinct on (bt_id) * from alloc order by bt_id, line_no) a
  join cust cu on cu.customer_id = a.customer_id

  union all
  -- created this month, paid out in a later month (or still pending): not in this month's payouts
  select date_trunc('month', b.created)::date, 2, 4, 'Payouts in transit', 'Stripe Clearing', 'Stripe Clearing (net of fees)', 'Payout timing',
         b.customer_id, b.source, -b.net_usd,
         'In Stripe at month-end, paid out later',
         initcap(b.type) || ' on ' || to_char(b.created, 'DD Mon') || ' → ' || coalesce('payout ' || b.payout_id || ' on ' || to_char(b.arrival_date, 'DD Mon YYYY'), 'still pending'),
         null
  from bal b
  where b.arrival_date is null or date_trunc('month', b.arrival_date) <> date_trunc('month', b.created)

  union all
  -- created in an earlier month, paid out this month
  select date_trunc('month', b.arrival_date)::date, 2, 4, 'Payouts in transit', 'Stripe Clearing', 'Stripe Clearing (net of fees)', 'Payout timing',
         b.customer_id, b.source, b.net_usd,
         'From last month, paid out this month',
         initcap(b.type) || ' on ' || to_char(b.created, 'DD Mon') || ' → payout ' || b.payout_id || ' on ' || to_char(b.arrival_date, 'DD Mon YYYY'),
         null
  from bal b
  where b.arrival_date is not null and date_trunc('month', b.arrival_date) <> date_trunc('month', b.created)

  union all
  select f.month, 2, 5, 'Deposit book errors', 'Operating Checking', 'Payouts → Deposits', 'Correcting entry',
         null, f.rc_id, f.credit_minus_debit,          -- a credit to an asset means the GL had too much
         f.memo, 'The bank account in the GL is off by this much; the ' || f.rc_id || ' correcting entry fixes it', f.rc_id
  from fixes f
  where f.account = 'Operating Checking'
)
select r.month, r.walk, r.step_order, r.step, r.gl_account, r.recon_check, r.row_type,
       r.customer_id, c.customer_name, r.source_id, r.amount_usd, r.reason, r.calculation, r.rc_id
from rows r
left join cust c on c.customer_id = r.customer_id
where r.month between '2024-10-01' and '2026-09-01'
  and r.amount_usd <> 0
;

create table mart.account_map as
-- account_map
-- The legend for the tab: the 7 GL accounts the subscription money passes through, in order from
-- contract to bank, with the walk step and recon check(s) that cover each one.

select * from (values
  (1, 'Subscription Revenue', 'Walk 1', 'Monthly plans · Annual plans · FX', 'Subscription Revenue',                                'ARR on the P&L: monthly plans as billed, annual plans as earned'),
  (2, 'Top-up Revenue',       'Walk 1', 'Top-ups (not ARR)',                 'Top-up Revenue',                                      'Revenue that is never ARR: one-off credit packs'),
  (3, 'Refunds & Allowances', 'Walk 1', 'Refunds',                           'Refunds',                                             'Lowers revenue without lowering ARR, unless the customer leaves'),
  (4, 'Deferred Revenue',     'Walk 2', 'Annual billed, not yet earned',     'Deferred Revenue (billed) · Deferred Revenue balance (month-end)', 'Annual ARR paid upfront and not yet earned'),
  (5, 'Merchant Fees',        'Walk 2', 'Merchant fees',                     'Merchant Fees',                                       'The cost of collecting: why cash is less than billed'),
  (6, 'Stripe Clearing',      'Walk 2', 'Payouts in transit',                'Stripe Clearing (net of fees)',                       'Collected by Stripe, not yet in the bank'),
  (7, 'Operating Checking',   'Walk 2', 'Deposit book errors (if any)',      'Payouts → Deposits',                                  'The bank: where the walk ends')
) as t("#", "GL account", "Walk", "Waterfall step", "Recon check", "Relationship to ARR")
;