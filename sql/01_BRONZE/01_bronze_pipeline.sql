-- ============================================================================
-- pipeline layer: bronze raw landing
-- description: ddl definitions, ingestion, and initial row count validation
-- ============================================================================

-- 0. ensure bronze schema exists
create schema if not exists bronze;

-- 1. ddl definitions for bronze landing tables
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

-- 2. reset tables for idempotent reload
truncate table bronze.products;
truncate table bronze.orders;
truncate table bronze.order_items;
truncate table bronze.order_item_refunds;
truncate table bronze.website_sessions;
truncate table bronze.website_pageviews;

-- 3. bulk data ingestion
-- note: replace data_dir with your local path or relative repository data directory
-- example: psql -v data_dir="/path/to/data" -f 01_bronze_pipeline.sql

copy bronze.products (product_id, created_at, product_name) 
from '/data/products.csv' 
with (format csv, header true);

copy bronze.orders (order_id, created_at, website_session_id, user_id, primary_product_id, items_purchased, price_usd, cogs_usd) 
from '/data/orders.csv' 
with (format csv, header true);

copy bronze.order_items (order_item_id, created_at, order_id, product_id, is_primary_item, price_usd, cogs_usd) 
from '/data/order_items.csv' 
with (format csv, header true);

copy bronze.order_item_refunds (order_item_refund_id, created_at, order_item_id, order_id, refund_amount_usd) 
from '/data/order_item_refunds.csv' 
with (format csv, header true);

copy bronze.website_sessions (website_session_id, created_at, user_id, is_repeat_session, utm_source, utm_campaign, utm_content, device_type, http_referer) 
from '/data/website_sessions.csv' 
with (format csv, header true);

copy bronze.website_pageviews (website_pageview_id, created_at, website_session_id, pageview_url) 
from '/data/website_pageviews.csv' 
with (format csv, header true);

-- 4. validation check
select 'bronze.products' as table_name, count(*) as total_rows from bronze.products
union all
select 'bronze.orders', count(*) from bronze.orders
union all
select 'bronze.order_items', count(*) from bronze.order_items
union all
select 'bronze.order_item_refunds', count(*) from bronze.order_item_refunds
union all
select 'bronze.website_sessions', count(*) from bronze.website_sessions
union all
select 'bronze.website_pageviews', count(*) from bronze.website_pageviews;
