-- ============================================================================
-- portfolio analytics: customer lifecycle and marketing intelligence
-- database: toy_shop
-- schema: gold
-- description: advanced analytical queries evaluating cohort retention,
--              customer lifetime value deciles, and first-touch attribution
-- ============================================================================

-- ============================================================================
-- query 1: monthly cohort retention matrix
-- business question: what percentage of first-time buyers return to place orders
-- in subsequent calendar months?
-- ============================================================================
with customer_orders as (
    select 
        foi.user_id,
        foi.order_id,
        d.calendar_date as order_date,
        date_trunc('month', d.calendar_date)::date as order_month,
        date_trunc('month', u.first_order_at)::date as cohort_month
    from gold.fact_order_items foi
    inner join gold.dim_date d 
        on foi.order_date_key = d.date_key
    inner join gold.dim_users u 
        on foi.user_id = u.user_id
    where u.first_order_at is not null
    group by foi.user_id, foi.order_id, d.calendar_date, u.first_order_at
),
cohort_sizes as (
    select 
        cohort_month,
        count(distinct user_id) as cohort_size
    from customer_orders
    group by cohort_month
),
cohort_activity as (
    select 
        co.cohort_month,
        co.order_month,
        extract(year from age(co.order_month, co.cohort_month)) * 12 +
        extract(month from age(co.order_month, co.cohort_month)) as month_number,
        count(distinct co.user_id) as active_users
    from customer_orders co
    group by co.cohort_month, co.order_month
)
select 
    to_char(ca.cohort_month, 'YYYY-MM') as cohort,
    cs.cohort_size,
    ca.month_number,
    ca.active_users,
    round(ca.active_users * 100.0 / cs.cohort_size, 2) as retention_rate_pct
from cohort_activity ca
inner join cohort_sizes cs 
    on ca.cohort_month = cs.cohort_month
where ca.month_number between 0 and 12
order by ca.cohort_month, ca.month_number;


-- ============================================================================
-- query 2: customer lifetime value decile breakdown
-- business question: how concentrated is revenue and margin among top buyer segments?
-- ============================================================================
with buyer_summary as (
    select 
        foi.user_id,
        count(distinct foi.order_id) as lifetime_orders,
        sum(foi.price_usd) as lifetime_gross_spend,
        sum(foi.refund_amount_usd) as lifetime_refunds,
        sum(foi.price_usd) - sum(foi.refund_amount_usd) as lifetime_net_spend,
        sum(foi.gross_margin_usd) as lifetime_gross_margin
    from gold.fact_order_items foi
    group by foi.user_id
),
deciled_buyers as (
    select 
        user_id,
        lifetime_orders,
        lifetime_gross_spend,
        lifetime_refunds,
        lifetime_net_spend,
        lifetime_gross_margin,
        ntile(10) over (order by lifetime_net_spend desc) as spend_decile
    from buyer_summary
)
select 
    spend_decile,
    count(user_id) as total_customers,
    round(avg(lifetime_orders), 2) as avg_orders_per_customer,
    round(min(lifetime_net_spend), 2) as min_net_spend,
    round(max(lifetime_net_spend), 2) as max_net_spend,
    round(sum(lifetime_net_spend), 2) as decile_total_net_spend,
    round(sum(lifetime_gross_margin), 2) as decile_total_margin,
    round(
        sum(lifetime_net_spend) * 100.0 / sum(sum(lifetime_net_spend)) over (), 
        2
    ) as pct_of_total_revenue
from deciled_buyers
group by spend_decile
order by spend_decile;


-- ============================================================================
-- query 3: first-touch marketing attribution
-- business question: which acquisition channels bring users with the highest
-- customer conversion, repeat frequency, and total net revenue?
-- ============================================================================
with first_touch_sessions as (
    select distinct on (s.user_id)
        s.user_id,
        s.website_session_id as first_session_id,
        s.session_started_at as acquisition_time,
        c.traffic_channel as acquisition_channel,
        coalesce(c.utm_source, 'direct') as acquisition_source,
        coalesce(c.utm_campaign, 'none') as acquisition_campaign
    from gold.fact_sessions s
    inner join gold.dim_channels c 
        on s.channel_key = c.channel_key
    order by s.user_id, s.session_started_at asc
),
user_order_aggregates as (
    select 
        user_id,
        count(distinct order_id) as total_orders,
        sum(price_usd) as lifetime_gross_revenue,
        sum(price_usd) - sum(refund_amount_usd) as lifetime_net_revenue
    from gold.fact_order_items
    group by user_id
)
select 
    fts.acquisition_channel,
    fts.acquisition_source,
    fts.acquisition_campaign,
    count(distinct fts.user_id) as acquired_users,
    count(distinct uoa.user_id) as converted_customers,
    round(
        count(distinct uoa.user_id) * 100.0 / nullif(count(distinct fts.user_id), 0), 
        2
    ) as acquisition_conversion_rate_pct,
    count(distinct uoa.user_id) filter (where uoa.total_orders > 1) as repeat_customers,
    coalesce(sum(uoa.lifetime_net_revenue), 0.00) as total_attributed_net_revenue,
    round(
        coalesce(sum(uoa.lifetime_net_revenue) / nullif(count(distinct uoa.user_id), 0), 0.00), 
        2
    ) as avg_revenue_per_paying_user
from first_touch_sessions fts
left join user_order_aggregates uoa 
    on fts.user_id = uoa.user_id
group by 
    fts.acquisition_channel,
    fts.acquisition_source,
    fts.acquisition_campaign
order by total_attributed_net_revenue desc;
