-- ============================================================================
-- script: 02_silver_transformations.sql
-- description: ddl, data cleaning, typing, and transformations from bronze to silver
-- database: toy_shop
-- ============================================================================

-- 0. initialize silver schema
create schema if not exists silver;

-- ============================================================================
-- 1. table: silver.website_sessions
-- ============================================================================

drop table if exists silver.website_sessions cascade;

create table silver.website_sessions (
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
    nullif(trim(utm_source), 'NULL') as utm_source,
    nullif(trim(utm_campaign), 'NULL') as utm_campaign,
    nullif(trim(utm_content), 'NULL') as utm_content,
    trim(device_type) as device_type,
    nullif(trim(http_referer), 'NULL') as http_referer,
    case 
        when nullif(trim(utm_source), 'NULL') is null 
             and nullif(trim(http_referer), 'NULL') is null 
             then 'direct_type_in'
        when nullif(trim(utm_source), 'NULL') is null 
             and nullif(trim(http_referer), 'NULL') is not null 
             then 'organic_search'
        when trim(utm_campaign) = 'brand' 
             then 'paid_brand'
        when trim(utm_campaign) = 'nonbrand' 
             then 'paid_nonbrand'
        when trim(utm_source) = 'socialbook' 
             then 'paid_social'
        else 'other'
    end as traffic_channel
from bronze.website_sessions;

create index idx_silver_sessions_user_id 
    on silver.website_sessions(user_id);

create index idx_silver_sessions_channel 
    on silver.website_sessions(traffic_channel);

-- ============================================================================
-- 2. table: silver.products
-- ============================================================================

drop table if exists silver.products cascade;

create table silver.products (
    product_id          int primary key,
    created_at          timestamp not null,
    product_name        text not null,
    _silver_loaded_at   timestamp with time zone default clock_timestamp()
);

insert into silver.products (
    product_id,
    created_at,
    product_name
)
select 
    product_id,
    created_at,
    trim(product_name) as product_name
from bronze.products;

-- ============================================================================
-- 3. table: silver.orders
-- ============================================================================

drop table if exists silver.orders cascade;

create table silver.orders (
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
    (price_usd - cogs_usd)::numeric(10, 2) as gross_margin_usd,
    round(((price_usd - cogs_usd)::numeric / price_usd::numeric), 4) as margin_rate
from bronze.orders;

create index idx_silver_orders_session_id 
    on silver.orders(website_session_id);

create index idx_silver_orders_user_id 
    on silver.orders(user_id);

-- ============================================================================
-- 4. table: silver.order_items
-- ============================================================================

drop table if exists silver.order_items cascade;

create table silver.order_items (
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
    (is_primary_item::int = 1) as is_primary_item,
    price_usd::numeric(10, 2),
    cogs_usd::numeric(10, 2),
    (price_usd - cogs_usd)::numeric(10, 2) as gross_margin_usd
from bronze.order_items;

create index idx_silver_order_items_order_id 
    on silver.order_items(order_id);

create index idx_silver_order_items_product_id 
    on silver.order_items(product_id);

-- ============================================================================
-- 5. table: silver.order_item_refunds
-- ============================================================================

drop table if exists silver.order_item_refunds cascade;

create table silver.order_item_refunds (
    order_item_refund_id    int primary key,
    created_at              timestamp not null,
    order_item_id           int not null references silver.order_items(order_item_id),
    order_id                int not null references silver.orders(order_id),
    refund_amount_usd       numeric(10, 2) not null,
    _silver_loaded_at       timestamp with time zone default clock_timestamp()
);

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

create index idx_silver_refunds_order_item_id 
    on silver.order_item_refunds(order_item_id);

create index idx_silver_refunds_order_id 
    on silver.order_item_refunds(order_id);

-- ============================================================================
-- 6. table: silver.website_pageviews
-- ============================================================================

drop table if exists silver.website_pageviews cascade;

create table silver.website_pageviews (
    website_pageview_id   int primary key,
    created_at            timestamp not null,
    website_session_id    int not null references silver.website_sessions(website_session_id),
    pageview_url          text not null,
    pageview_sequence     smallint not null,
    _silver_loaded_at     timestamp with time zone default clock_timestamp()
);

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
    trim(pageview_url) as pageview_url,
    row_number() over (
        partition by website_session_id 
        order by created_at, website_pageview_id
    ) as pageview_sequence
from bronze.website_pageviews;

create index idx_silver_pageviews_session_id 
    on silver.website_pageviews(website_session_id);

create index idx_silver_pageviews_url 
    on silver.website_pageviews(pageview_url);

-- ============================================================================
-- 7. verification audit
-- ============================================================================

select 'website_sessions' as table_name, count(*) as record_count from silver.website_sessions
union all
select 'products', count(*) from silver.products
union all
select 'orders', count(*) from silver.orders
union all
select 'order_items', count(*) from silver.order_items
union all
select 'order_item_refunds', count(*) from silver.order_item_refunds
union all
select 'website_pageviews', count(*) from silver.website_pageviews;
