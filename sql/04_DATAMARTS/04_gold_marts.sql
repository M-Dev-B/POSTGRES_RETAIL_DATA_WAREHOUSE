-- ============================================================================
-- gold layer analytical marts and reporting views
-- database: toy_shop
-- schema: gold
-- description: pre-aggregated views for bi reporting and ad-hoc analysis
-- ============================================================================

-- ============================================================================
-- 1. mart definitions
-- ============================================================================

-- ----------------------------------------------------------------------------
-- mart: gold.mart_channel_performance
-- grain: one row per channel, utm campaign, and device slice
-- purpose: evaluates marketing acquisition, bounce rates, and roas
-- ----------------------------------------------------------------------------
create or replace view gold.mart_channel_performance as
select 
    c.traffic_channel,
    c.utm_source,
    c.utm_campaign,
    c.device_type,
    count(s.website_session_id) as total_sessions,
    count(distinct s.user_id) as unique_visitors,
    count(*) filter (where s.is_bounced) as bounced_sessions,
    round(count(*) filter (where s.is_bounced) * 100.0 / count(s.website_session_id), 2) as bounce_rate_pct,
    count(*) filter (where s.has_order) as total_orders,
    round(count(*) filter (where s.has_order) * 100.0 / count(s.website_session_id), 2) as conversion_rate_pct,
    sum(s.order_revenue_usd) as total_revenue_usd,
    round(coalesce(sum(s.order_revenue_usd) / nullif(count(s.website_session_id), 0), 0), 2) as revenue_per_session_usd
from gold.fact_sessions s
inner join gold.dim_channels c 
    on s.channel_key = c.channel_key
group by 
    c.traffic_channel,
    c.utm_source,
    c.utm_campaign,
    c.device_type;


-- ----------------------------------------------------------------------------
-- mart: gold.mart_product_performance
-- grain: one row per catalog product
-- purpose: tracks volume, revenue, gross margins, and return rates
-- ----------------------------------------------------------------------------
create or replace view gold.mart_product_performance as
select 
    p.product_id,
    p.product_name,
    count(foi.order_item_id) as units_sold,
    count(distinct foi.order_id) as orders_included,
    sum(foi.price_usd) as gross_revenue_usd,
    sum(foi.cogs_usd) as total_cogs_usd,
    sum(foi.gross_margin_usd) as total_gross_margin_usd,
    count(*) filter (where foi.is_refunded) as units_refunded,
    sum(foi.refund_amount_usd) as total_refund_amount_usd,
    sum(foi.price_usd) - sum(foi.refund_amount_usd) as net_revenue_usd,
    round(count(*) filter (where foi.is_refunded) * 100.0 / count(foi.order_item_id), 2) as refund_rate_pct
from gold.fact_order_items foi
inner join gold.dim_products p 
    on foi.product_id = p.product_id
group by 
    p.product_id,
    p.product_name;


-- ----------------------------------------------------------------------------
-- mart: gold.mart_monthly_business_summary
-- grain: one row per calendar year and month
-- purpose: high-level business scorecard across web traffic, sales, and profit
-- ----------------------------------------------------------------------------
create or replace view gold.mart_monthly_business_summary as
select 
    d.year,
    d.month,
    d.month_name,
    count(distinct s.website_session_id) as total_sessions,
    count(distinct s.user_id) as active_visitors,
    count(distinct foi.order_id) as total_orders,
    round(count(distinct s.website_session_id) filter (where s.has_order) * 100.0 / nullif(count(distinct s.website_session_id), 0), 2) as session_conversion_rate_pct,
    coalesce(sum(foi.price_usd), 0.00) as gross_revenue_usd,
    coalesce(sum(foi.refund_amount_usd), 0.00) as refund_amount_usd,
    coalesce(sum(foi.price_usd) - sum(foi.refund_amount_usd), 0.00) as net_revenue_usd,
    coalesce(sum(foi.gross_margin_usd), 0.00) as gross_profit_usd
from gold.dim_date d
left join gold.fact_sessions s 
    on d.date_key = s.session_date_key
left join gold.fact_order_items foi 
    on d.date_key = foi.order_date_key
group by 
    d.year,
    d.month,
    d.month_name
order by 
    d.year,
    d.month;


-- ============================================================================
-- 2. analytical test queries
-- ============================================================================

-- query a: product profitability and refund rates
select 
    product_name,
    units_sold,
    net_revenue_usd,
    round(total_gross_margin_usd * 100.0 / nullif(gross_revenue_usd, 0), 2) as margin_pct,
    refund_rate_pct
from gold.mart_product_performance
order by net_revenue_usd desc;

-- query b: top marketing channels by net revenue and conversion rate
select 
    traffic_channel,
    device_type,
    total_sessions,
    conversion_rate_pct,
    total_revenue_usd,
    revenue_per_session_usd
from gold.mart_channel_performance
order by total_revenue_usd desc;

-- query c: monthly run rate and growth trend
select 
    year,
    month,
    month_name,
    total_sessions,
    total_orders,
    session_conversion_rate_pct,
    net_revenue_usd,
    gross_profit_usd
from gold.mart_monthly_business_summary
where total_sessions > 0
order by year, month;
