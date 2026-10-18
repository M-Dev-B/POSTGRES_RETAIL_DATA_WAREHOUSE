-- ============================================================================
-- pipeline layer: gold dimensional star schema
-- database: toy_shop
-- schema: gold
-- description: conformed dimensions, granular facts, and optimized staging etl
-- ============================================================================

-- 0. ensure gold schema exists
create schema if not exists gold;

-- ============================================================================
-- 1. dimension tables
-- ============================================================================

-- ----------------------------------------------------------------------------
-- dimension: gold.dim_date
-- grain: one row per calendar day
-- ----------------------------------------------------------------------------
create table if not exists gold.dim_date (
    date_key        int primary key,
    calendar_date   date not null unique,
    year            smallint not null,
    quarter         smallint not null,
    month           smallint not null,
    month_name      text not null,
    week_of_year    smallint not null,
    day_of_month    smallint not null,
    day_of_week     smallint not null,
    day_name        text not null,
    is_weekend      boolean not null
);

insert into gold.dim_date (
    date_key,
    calendar_date,
    year,
    quarter,
    month,
    month_name,
    week_of_year,
    day_of_month,
    day_of_week,
    day_name,
    is_weekend
)
with calendar_series as (
    select datum::date as calendar_date
    from generate_series('2012-01-01'::date, '2015-12-31'::date, '1 day'::interval) as datum
)
select 
    to_char(calendar_date, 'YYYYMMDD')::int as date_key,
    calendar_date,
    extract(year from calendar_date)::smallint as year,
    extract(quarter from calendar_date)::smallint as quarter,
    extract(month from calendar_date)::smallint as month,
    trim(to_char(calendar_date, 'Month')) as month_name,
    extract(week from calendar_date)::smallint as week_of_year,
    extract(day from calendar_date)::smallint as day_of_month,
    extract(isodow from calendar_date)::smallint as day_of_week,
    trim(to_char(calendar_date, 'Day')) as day_name,
    extract(isodow from calendar_date) in (6, 7) as is_weekend
from calendar_series
on conflict (date_key) do nothing;


-- ----------------------------------------------------------------------------
-- dimension: gold.dim_products
-- grain: one row per catalog product
-- ----------------------------------------------------------------------------
create table if not exists gold.dim_products (
    product_id          int primary key,
    product_name        text not null,
    launched_at         timestamp not null,
    launch_date_key     int not null references gold.dim_date(date_key)
);

insert into gold.dim_products (
    product_id,
    product_name,
    launched_at,
    launch_date_key
)
select 
    p.product_id,
    p.product_name,
    p.created_at as launched_at,
    to_char(p.created_at, 'YYYYMMDD')::int as launch_date_key
from silver.products p 
order by p.product_id
on conflict (product_id) do nothing;


-- ----------------------------------------------------------------------------
-- dimension: gold.dim_channels
-- grain: one row per unique marketing channel, campaign, and device pairing
-- ----------------------------------------------------------------------------
create table if not exists gold.dim_channels (
    channel_key     int generated always as identity primary key,
    traffic_channel text not null,
    utm_source      text,
    utm_campaign    text,
    utm_content     text,
    device_type     text not null
);

insert into gold.dim_channels (
    traffic_channel,
    utm_source,
    utm_campaign,
    utm_content,
    device_type
)
select distinct
    traffic_channel,
    utm_source,
    utm_campaign,
    utm_content,
    device_type
from silver.website_sessions
order by traffic_channel, utm_source, utm_campaign, utm_content, device_type;


-- ----------------------------------------------------------------------------
-- dimension: gold.dim_users
-- grain: one row per unique user with lifetime engagement metrics
-- ----------------------------------------------------------------------------
create table if not exists gold.dim_users (
    user_id                 int primary key,
    first_session_at        timestamp not null,
    first_session_date_key  int not null references gold.dim_date(date_key),
    first_order_at          timestamp,
    first_order_date_key    int references gold.dim_date(date_key),
    total_orders            int not null default 0,
    total_spend_usd         numeric(10, 2) not null default 0.00,
    is_repeat_buyer         boolean not null default false
);

insert into gold.dim_users (
    user_id,
    first_session_at,
    first_session_date_key,
    first_order_at,
    first_order_date_key,
    total_orders,
    total_spend_usd,
    is_repeat_buyer
)
with user_sessions as (
    select 
        user_id,
        min(created_at) as first_session_at
    from silver.website_sessions
    group by user_id
),
user_orders as (
    select 
        user_id,
        min(created_at) as first_order_at,
        count(order_id) as total_orders,
        sum(price_usd) as total_spend_usd
    from silver.orders
    group by user_id
)
select 
    s.user_id,
    s.first_session_at,
    to_char(s.first_session_at, 'YYYYMMDD')::int as first_session_date_key,
    o.first_order_at,
    case 
        when o.first_order_at is not null 
        then to_char(o.first_order_at, 'YYYYMMDD')::int 
        else null 
    end as first_order_date_key,
    coalesce(o.total_orders, 0) as total_orders,
    coalesce(o.total_spend_usd, 0.00) as total_spend_usd,
    coalesce(o.total_orders, 0) > 1 as is_repeat_buyer
from user_sessions s
left join user_orders o on s.user_id = o.user_id
order by s.user_id
on conflict (user_id) do nothing;


-- ============================================================================
-- 2. fact tables
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fact: gold.fact_order_items
-- grain: one row per purchased line item
-- ----------------------------------------------------------------------------
create table if not exists gold.fact_order_items (
    order_item_id        int primary key,
    order_id             int not null,
    order_item_refund_id int,
    order_date_key       int not null references gold.dim_date(date_key),
    user_id              int not null references gold.dim_users(user_id),
    product_id           int not null references gold.dim_products(product_id),
    primary_product_id   int not null references gold.dim_products(product_id),
    channel_key          int not null references gold.dim_channels(channel_key),
    website_session_id   int not null,
    ordered_at           timestamp not null,
    price_usd            numeric(10, 2) not null,
    cogs_usd             numeric(10, 2) not null,
    gross_margin_usd     numeric(10, 2) not null,
    is_primary_item      boolean not null,
    is_refunded          boolean not null,
    refund_amount_usd    numeric(10, 2) not null default 0.00,
    refunded_at          timestamp
);

insert into gold.fact_order_items (
    order_item_id,
    order_id,
    order_item_refund_id,
    order_date_key,
    user_id,
    product_id,
    primary_product_id,
    channel_key,
    website_session_id,
    ordered_at,
    price_usd,
    cogs_usd,
    gross_margin_usd,
    is_primary_item,
    is_refunded,
    refund_amount_usd,
    refunded_at
)
select 
    oi.order_item_id,
    oi.order_id,
    oir.order_item_refund_id,
    to_char(oi.created_at, 'YYYYMMDD')::int as order_date_key,
    o.user_id,
    oi.product_id,
    o.primary_product_id,
    c.channel_key,
    o.website_session_id,
    oi.created_at as ordered_at,
    oi.price_usd,
    oi.cogs_usd,
    round(oi.price_usd - oi.cogs_usd, 2) as gross_margin_usd,
    oi.is_primary_item,
    oir.order_item_refund_id is not null as is_refunded,
    coalesce(oir.refund_amount_usd, 0.00) as refund_amount_usd,
    oir.created_at as refunded_at
from silver.order_items oi
inner join silver.orders o 
    on oi.order_id = o.order_id
left join silver.order_item_refunds oir 
    on oi.order_item_id = oir.order_item_id
inner join silver.website_sessions ws 
    on o.website_session_id = ws.website_session_id
inner join gold.dim_channels c 
    on ws.traffic_channel = c.traffic_channel
    and ws.device_type = c.device_type
    and ws.utm_source is not distinct from c.utm_source
    and ws.utm_campaign is not distinct from c.utm_campaign
    and ws.utm_content is not distinct from c.utm_content
order by oi.order_item_id
on conflict (order_item_id) do nothing;


-- ----------------------------------------------------------------------------
-- fact: gold.fact_sessions
-- grain: one row per website session
-- ----------------------------------------------------------------------------
create table if not exists gold.fact_sessions (
    website_session_id      int primary key,
    session_date_key        int not null references gold.dim_date(date_key),
    user_id                 int not null references gold.dim_users(user_id),
    channel_key             int not null references gold.dim_channels(channel_key),
    is_repeat_session       boolean not null,
    session_started_at      timestamp not null,
    session_ended_at        timestamp not null,
    duration_seconds        int not null,
    pageview_count          int not null,
    is_bounced              boolean not null,
    has_order               boolean not null,
    order_id                int,
    order_revenue_usd       numeric(10, 2) not null default 0.00
);

-- stage 1: pre-aggregate pageviews into indexed temporary table
drop table if exists temp_session_pageview_metrics;

create temp table temp_session_pageview_metrics as
select 
    website_session_id,
    min(created_at) as session_started_at,
    max(created_at) as session_ended_at,
    extract(epoch from (max(created_at) - min(created_at)))::int as duration_seconds,
    count(website_pageview_id) as pageview_count
from silver.website_pageviews
group by website_session_id;

create index idx_tmp_session_pv on temp_session_pageview_metrics (website_session_id);

-- stage 2: resolve surrogate channel keys into indexed temporary map
drop table if exists temp_session_channels;

create temp table temp_session_channels as
select 
    ws.website_session_id,
    c.channel_key
from silver.website_sessions ws
inner join gold.dim_channels c
    on ws.traffic_channel = c.traffic_channel
    and ws.device_type = c.device_type
    and (ws.utm_source = c.utm_source or (ws.utm_source is null and c.utm_source is null))
    and (ws.utm_campaign = c.utm_campaign or (ws.utm_campaign is null and c.utm_campaign is null))
    and (ws.utm_content = c.utm_content or (ws.utm_content is null and c.utm_content is null));

create index idx_tmp_session_ch on temp_session_channels (website_session_id);

-- stage 3: insert into fact_sessions via primary integer joins
insert into gold.fact_sessions (
    website_session_id,
    session_date_key,
    user_id,
    channel_key,
    is_repeat_session,
    session_started_at,
    session_ended_at,
    duration_seconds,
    pageview_count,
    is_bounced,
    has_order,
    order_id,
    order_revenue_usd
)
select 
    ws.website_session_id,
    to_char(ws.created_at, 'YYYYMMDD')::int as session_date_key,
    ws.user_id,
    sc.channel_key,
    ws.is_repeat_session = 1 as is_repeat_session,
    pm.session_started_at,
    pm.session_ended_at,
    pm.duration_seconds,
    pm.pageview_count,
    pm.pageview_count = 1 as is_bounced,
    o.order_id is not null as has_order,
    o.order_id,
    coalesce(o.price_usd, 0.00) as order_revenue_usd
from silver.website_sessions ws
inner join temp_session_channels sc
    on ws.website_session_id = sc.website_session_id
inner join temp_session_pageview_metrics pm 
    on ws.website_session_id = pm.website_session_id
left join silver.orders o 
    on ws.website_session_id = o.website_session_id
on conflict (website_session_id) do nothing;

-- cleanup temporary staging tables
drop table if exists temp_session_pageview_metrics;
drop table if exists temp_session_channels;


-- ============================================================================
-- 3. validation and reconciliation checks
-- ============================================================================

-- verify orders fact integrity
select 
    count(*) as total_items,
    count(distinct order_id) as total_orders,
    sum(price_usd) as total_gross_revenue,
    sum(refund_amount_usd) as total_refunded,
    sum(price_usd) - sum(refund_amount_usd) as net_revenue
from gold.fact_order_items;

-- verify sessions fact integrity
select 
    count(*) as total_sessions,
    count(distinct user_id) as unique_users,
    count(*) filter (where is_bounced) as bounced_sessions,
    round(count(*) filter (where is_bounced) * 100.0 / count(*), 2) as bounce_rate_pct,
    count(*) filter (where has_order) as orders_placed,
    round(count(*) filter (where has_order) * 100.0 / count(*), 2) as conversion_rate_pct,
    sum(order_revenue_usd) as total_session_revenue
from gold.fact_sessions;
