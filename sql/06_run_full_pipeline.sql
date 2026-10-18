-- ============================================================================
-- script: run_pipeline.sql
-- description: automated, idempotent medallion pipeline runner (bronze -> silver -> gold)
-- database: toy_shop
-- ============================================================================

\set ON_ERROR_STOP on

-- optimize local session memory for high-volume aggregations
set work_mem = '256MB';
set maintenance_work_mem = '512MB';

select clock_timestamp() as pipeline_started_at;

-- ============================================================================
-- step 1: bronze layer initialization & ingestion
-- ============================================================================
begin;

create schema if not exists bronze;

create table if not exists bronze.website_sessions (
    website_session_id    int,
    created_at            timestamp,
    user_id               int,
    is_repeat_session     int,
    utm_source            text,
    utm_campaign          text,
    utm_content           text,
    device_type           text,
    http_referer          text,
    _loaded_at            timestamp with time zone default clock_timestamp()
);

create table if not exists bronze.website_pageviews (
    website_pageview_id   int,
    created_at            timestamp,
    website_session_id    int,
    pageview_url          text,
    _loaded_at            timestamp with time zone default clock_timestamp()
);

create table if not exists bronze.products (
    product_id            int,
    created_at            timestamp,
    product_name          text,
    _loaded_at            timestamp with time zone default clock_timestamp()
);

create table if not exists bronze.orders (
    order_id              int,
    created_at            timestamp,
    website_session_id    int,
    user_id               int,
    primary_product_id    int,
    items_purchased       int,
    price_usd             numeric(10, 2),
    cogs_usd              numeric(10, 2),
    _loaded_at            timestamp with time zone default clock_timestamp()
);

create table if not exists bronze.order_items (
    order_item_id         int,
    created_at            timestamp,
    order_id              int,
    product_id            int,
    is_primary_item       int,
    price_usd             numeric(10, 2),
    cogs_usd              numeric(10, 2),
    _loaded_at            timestamp with time zone default clock_timestamp()
);

create table if not exists bronze.order_item_refunds (
    order_item_refund_id  int,
    created_at            timestamp,
    order_item_id         int,
    order_id              int,
    refund_amount_usd     numeric(10, 2),
    _loaded_at            timestamp with time zone default clock_timestamp()
);

-- idempotent reset of bronze staging tables
truncate table 
    bronze.products,
    bronze.orders,
    bronze.order_items,
    bronze.order_item_refunds,
    bronze.website_sessions,
    bronze.website_pageviews;

commit;

-- client-side ingestion from local data directory
\copy bronze.products (product_id, created_at, product_name) from 'data/products.csv' with (format csv, header true);
\copy bronze.orders (order_id, created_at, website_session_id, user_id, primary_product_id, items_purchased, price_usd, cogs_usd) from 'data/orders.csv' with (format csv, header true);
\copy bronze.order_items (order_item_id, created_at, order_id, product_id, is_primary_item, price_usd, cogs_usd) from 'data/order_items.csv' with (format csv, header true);
\copy bronze.order_item_refunds (order_item_refund_id, created_at, order_item_id, order_id, refund_amount_usd) from 'data/order_item_refunds.csv' with (format csv, header true);
\copy bronze.website_sessions (website_session_id, created_at, user_id, is_repeat_session, utm_source, utm_campaign, utm_content, device_type, http_referer) from 'data/website_sessions.csv' with (format csv, header true);
\copy bronze.website_pageviews (website_pageview_id, created_at, website_session_id, pageview_url) from 'data/website_pageviews.csv' with (format csv, header true);


-- ============================================================================
-- step 2: silver layer transformations
-- ============================================================================
begin;

create schema if not exists silver;

create table if not exists silver.website_sessions (
    website_session_id    int primary key,
    created_at            timestamp not null,
    user_id               int not null,
    is_repeat_session     smallint not null,
    utm_source            text,
    utm_campaign          text,
    utm_content           text,
    device_type           text,
    http_referer          text,
    traffic_channel       text not null,
    _silver_loaded_at     timestamp with time zone default clock_timestamp()
);

create table if not exists silver.products (
    product_id          int primary key,
    created_at          timestamp not null,
    product_name        text not null,
    _silver_loaded_at   timestamp with time zone default clock_timestamp()
);

create table if not exists silver.orders (
    order_id              int primary key,
    created_at            timestamp not null,
    website_session_id    int not null references silver.website_sessions(website_session_id),
    user_id               int not null,
    primary_product_id    int not null references silver.products(product_id),
    items_purchased       smallint not null,
    price_usd             numeric(10, 2) not null,
    cogs_usd              numeric(10, 2) not null,
    gross_margin_usd      numeric(10, 2) not null,
    margin_rate           numeric(5, 4) not null,
    _silver_loaded_at     timestamp with time zone default clock_timestamp()
);

create table if not exists silver.order_items (
    order_item_id         int primary key,
    created_at            timestamp not null,
    order_id              int not null references silver.orders(order_id),
    product_id            int not null references silver.products(product_id),
    is_primary_item       boolean not null,
    price_usd             numeric(10, 2) not null,
    cogs_usd              numeric(10, 2) not null,
    gross_margin_usd      numeric(10, 2) not null,
    _silver_loaded_at     timestamp with time zone default clock_timestamp()
);

create table if not exists silver.order_item_refunds (
    order_item_refund_id    int primary key,
    created_at              timestamp not null,
    order_item_id           int not null references silver.order_items(order_item_id),
    order_id                int not null references silver.orders(order_id),
    refund_amount_usd       numeric(10, 2) not null,
    _silver_loaded_at       timestamp with time zone default clock_timestamp()
);

create table if not exists silver.website_pageviews (
    website_pageview_id   int primary key,
    created_at            timestamp not null,
    website_session_id    int not null references silver.website_sessions(website_session_id),
    pageview_url          text not null,
    pageview_sequence     smallint not null,
    _silver_loaded_at     timestamp with time zone default clock_timestamp()
);

-- truncate cascade handles dependent foreign keys cleanly
truncate table silver.website_sessions, silver.products cascade;

-- load silver.website_sessions
insert into silver.website_sessions (
    website_session_id,
    created_at,
    user_id,
    is_repeat_session,
    utm_source,
    utm_campaign,
    utm_content,
    device_type,
    http_referer,
    traffic_channel
)
select 
    website_session_id,
    created_at,
    user_id,
    is_repeat_session,
    nullif(trim(utm_source), 'NULL'),
    nullif(trim(utm_campaign), 'NULL'),
    nullif(trim(utm_content), 'NULL'),
    trim(device_type),
    nullif(trim(http_referer), 'NULL'),
    case 
        when nullif(trim(utm_source), 'NULL') is null and nullif(trim(http_referer), 'NULL') is null then 'direct_type_in'
        when nullif(trim(utm_source), 'NULL') is null and nullif(trim(http_referer), 'NULL') is not null then 'organic_search'
        when trim(utm_campaign) = 'brand' then 'paid_brand'
        when trim(utm_campaign) = 'nonbrand' then 'paid_nonbrand'
        when trim(utm_source) = 'socialbook' then 'paid_social'
        else 'other'
    end
from bronze.website_sessions;

-- load silver.products
insert into silver.products (product_id, created_at, product_name)
select product_id, created_at, trim(product_name)
from bronze.products;

-- load silver.orders
insert into silver.orders (
    order_id,
    created_at,
    website_session_id,
    user_id,
    primary_product_id,
    items_purchased,
    price_usd,
    cogs_usd,
    gross_margin_usd,
    margin_rate
)
select 
    order_id,
    created_at,
    website_session_id,
    user_id,
    primary_product_id,
    items_purchased,
    price_usd::numeric(10, 2),
    cogs_usd::numeric(10, 2),
    (price_usd - cogs_usd)::numeric(10, 2),
    round(((price_usd - cogs_usd)::numeric / price_usd::numeric), 4)
from bronze.orders;

-- load silver.order_items
insert into silver.order_items (
    order_item_id,
    created_at,
    order_id,
    product_id,
    is_primary_item,
    price_usd,
    cogs_usd,
    gross_margin_usd
)
select 
    order_item_id,
    created_at,
    order_id,
    product_id,
    (is_primary_item::int = 1),
    price_usd::numeric(10, 2),
    cogs_usd::numeric(10, 2),
    (price_usd - cogs_usd)::numeric(10, 2)
from bronze.order_items;

-- load silver.order_item_refunds
insert into silver.order_item_refunds (
    order_item_refund_id,
    created_at,
    order_item_id,
    order_id,
    refund_amount_usd
)
select 
    order_item_refund_id,
    created_at,
    order_item_id,
    order_id,
    refund_amount_usd::numeric(10, 2)
from bronze.order_item_refunds;

-- load silver.website_pageviews
insert into silver.website_pageviews (
    website_pageview_id,
    created_at,
    website_session_id,
    pageview_url,
    pageview_sequence
)
select 
    website_pageview_id,
    created_at,
    website_session_id,
    trim(pageview_url),
    row_number() over (partition by website_session_id order by created_at, website_pageview_id)
from bronze.website_pageviews;

commit;


-- ============================================================================
-- step 3: gold star schema generation
-- ============================================================================
begin;

create schema if not exists gold;

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

create table if not exists gold.dim_products (
    product_id          int primary key,
    product_name        text not null,
    launched_at         timestamp not null,
    launch_date_key     int not null references gold.dim_date(date_key)
);

create table if not exists gold.dim_channels (
    channel_key     int generated always as identity primary key,
    traffic_channel text not null,
    utm_source      text,
    utm_campaign    text,
    utm_content     text,
    device_type     text not null
);

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

-- idempotent truncate of facts and dependent dimensions
truncate table 
    gold.fact_order_items, 
    gold.fact_sessions, 
    gold.dim_users, 
    gold.dim_products, 
    gold.dim_channels 
cascade;

-- populate dim_date
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
    to_char(calendar_date, 'YYYYMMDD')::int,
    calendar_date,
    extract(year from calendar_date)::smallint,
    extract(quarter from calendar_date)::smallint,
    extract(month from calendar_date)::smallint,
    trim(to_char(calendar_date, 'Month')),
    extract(week from calendar_date)::smallint,
    extract(day from calendar_date)::smallint,
    extract(isodow from calendar_date)::smallint,
    trim(to_char(calendar_date, 'Day')),
    extract(isodow from calendar_date) in (6, 7)
from calendar_series
on conflict (date_key) do nothing;

-- populate dim_products
insert into gold.dim_products (product_id, product_name, launched_at, launch_date_key)
select 
    p.product_id,
    p.product_name,
    p.created_at,
    to_char(p.created_at, 'YYYYMMDD')::int
from silver.products p 
order by p.product_id;

-- populate dim_channels
insert into gold.dim_channels (traffic_channel, utm_source, utm_campaign, utm_content, device_type)
select distinct
    traffic_channel,
    utm_source,
    utm_campaign,
    utm_content,
    device_type
from silver.website_sessions
order by traffic_channel, utm_source, utm_campaign, utm_content, device_type;

-- populate dim_users
with user_sessions as (
    select user_id, min(created_at) as first_session_at
    from silver.website_sessions
    group by user_id
),
user_orders as (
    select user_id, min(created_at) as first_order_at, count(order_id) as total_orders, sum(price_usd) as total_spend_usd
    from silver.orders
    group by user_id
)
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
select 
    s.user_id,
    s.first_session_at,
    to_char(s.first_session_at, 'YYYYMMDD')::int,
    o.first_order_at,
    case when o.first_order_at is not null then to_char(o.first_order_at, 'YYYYMMDD')::int else null end,
    coalesce(o.total_orders, 0),
    coalesce(o.total_spend_usd, 0.00),
    coalesce(o.total_orders, 0) > 1
from user_sessions s
left join user_orders o on s.user_id = o.user_id;

-- populate fact_order_items
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
    to_char(oi.created_at, 'YYYYMMDD')::int,
    o.user_id,
    oi.product_id,
    o.primary_product_id,
    c.channel_key,
    o.website_session_id,
    oi.created_at,
    oi.price_usd,
    oi.cogs_usd,
    round(oi.price_usd - oi.cogs_usd, 2),
    oi.is_primary_item,
    oir.order_item_refund_id is not null,
    coalesce(oir.refund_amount_usd, 0.00),
    oir.created_at
from silver.order_items oi
inner join silver.orders o on oi.order_id = o.order_id
left join silver.order_item_refunds oir on oi.order_item_id = oir.order_item_id
inner join silver.website_sessions ws on o.website_session_id = ws.website_session_id
inner join gold.dim_channels c 
    on ws.traffic_channel = c.traffic_channel
    and ws.device_type = c.device_type
    and ws.utm_source is not distinct from c.utm_source
    and ws.utm_campaign is not distinct from c.utm_campaign
    and ws.utm_content is not distinct from c.utm_content;

-- populate fact_sessions via staging tables
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
    to_char(ws.created_at, 'YYYYMMDD')::int,
    ws.user_id,
    sc.channel_key,
    ws.is_repeat_session = 1,
    pm.session_started_at,
    pm.session_ended_at,
    pm.duration_seconds,
    pm.pageview_count,
    pm.pageview_count = 1,
    o.order_id is not null,
    o.order_id,
    coalesce(o.price_usd, 0.00)
from silver.website_sessions ws
inner join temp_session_channels sc on ws.website_session_id = sc.website_session_id
inner join temp_session_pageview_metrics pm on ws.website_session_id = pm.website_session_id
left join silver.orders o on ws.website_session_id = o.website_session_id;

drop table if exists temp_session_pageview_metrics;
drop table if exists temp_session_channels;

commit;

-- ============================================================================
-- step 4: analytical data marts refresh
-- ============================================================================
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
inner join gold.dim_channels c on s.channel_key = c.channel_key
group by c.traffic_channel, c.utm_source, c.utm_campaign, c.device_type;

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
inner join gold.dim_products p on foi.product_id = p.product_id
group by p.product_id, p.product_name;

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
left join gold.fact_sessions s on d.date_key = s.session_date_key
left join gold.fact_order_items foi on d.date_key = foi.order_date_key
group by d.year, d.month, d.month_name
order by d.year, d.month;

select clock_timestamp() as pipeline_completed_at;
