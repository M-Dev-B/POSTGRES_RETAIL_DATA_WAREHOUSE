-- ============================================================================
-- script: 02_bronze_data_quality_audit.sql
-- description: data profiling, integrity checks, and validation on bronze layer
--              with remediation runbooks for failed checks
-- database: toy_shop
-- ============================================================================

-- ============================================================================
-- 1. primary key uniqueness and duplicate check across all tables
-- ============================================================================

select 
    'bronze.website_sessions' as table_name,
    count(*) as total_rows,
    count(distinct website_session_id) as distinct_keys,
    count(*) - count(distinct website_session_id) as duplicate_keys
from bronze.website_sessions

union all

select 
    'bronze.website_pageviews',
    count(*),
    count(distinct website_pageview_id),
    count(*) - count(distinct website_pageview_id)
from bronze.website_pageviews

union all

select 
    'bronze.products',
    count(*),
    count(distinct product_id),
    count(*) - count(distinct product_id)
from bronze.products

union all

select 
    'bronze.orders',
    count(*),
    count(distinct order_id),
    count(*) - count(distinct order_id)
from bronze.orders

union all

select 
    'bronze.order_items',
    count(*),
    count(distinct order_item_id),
    count(*) - count(distinct order_item_id)
from bronze.order_items

union all

select 
    'bronze.order_item_refunds',
    count(*),
    count(distinct order_item_refund_id),
    count(*) - count(distinct order_item_refund_id)
from bronze.order_item_refunds;

-- remediation runbook: primary key duplicates
-- failure trigger: duplicate_keys > 0
-- action: apply a window deduplication pattern when loading into silver using row_number():
/*
with deduped_records as (
    select 
        *,
        row_number() over (
            partition by website_session_id 
            order by _loaded_at desc, created_at desc
        ) as row_num
    from bronze.website_sessions
)
select * 
from deduped_records 
where row_num = 1;
*/


-- ============================================================================
-- 2. table: bronze.website_sessions profiling
-- ============================================================================

select 
    count(*) as total_sessions,
    min(created_at) as earliest_session,
    max(created_at) as latest_session,
    count(distinct user_id) as unique_users,
    count(*) filter (where website_session_id is null) as null_pk_count,
    count(*) filter (where user_id is null) as null_user_count,
    count(*) filter (where is_repeat_session not in (0, 1)) as invalid_repeat_flag,
    count(*) filter (where utm_source = 'NULL') as literal_null_utm_source,
    count(*) filter (where utm_campaign = 'NULL') as literal_null_utm_campaign,
    count(*) filter (where http_referer = 'NULL') as literal_null_http_referer
from bronze.website_sessions;

select 
    utm_source,
    utm_campaign,
    device_type,
    count(*) as session_count,
    count(*) filter (where http_referer is null or http_referer = 'NULL') as direct_or_no_referer,
    count(*) filter (where http_referer is not null and http_referer != 'NULL') as with_referer
from bronze.website_sessions
group by utm_source, utm_campaign, device_type
order by session_count desc;

-- remediation runbook: bronze.website_sessions
-- failure 1: null_pk_count > 0
-- action: drop null primary key records during silver ingestion: where website_session_id is not null
-- failure 2: literal_null_utm_source > 0 or literal_null_http_referer > 0
-- action: wrap raw text in nullif(trim(column_name), 'NULL')
-- failure 3: invalid_repeat_flag > 0
-- action: coalesce or cast using case when is_repeat_session = 1 then 1 else 0 end


-- ============================================================================
-- 3. table: bronze.products profiling
-- ============================================================================

select 
    count(*) as total_products,
    count(distinct product_id) as distinct_product_ids,
    count(*) filter (where product_id is null) as null_product_ids,
    count(*) filter (where product_name is null or trim(product_name) = '') as empty_product_names,
    min(created_at) as earliest_product_launch,
    max(created_at) as latest_product_launch
from bronze.products;

select 
    product_id,
    product_name,
    created_at
from bronze.products
order by product_id;

-- remediation runbook: bronze.products
-- failure 1: null_product_ids > 0
-- action: reject record and log to an error table; dimensions require non-null primary keys
-- failure 2: empty_product_names > 0
-- action: coalesce(nullif(trim(product_name), ''), 'unknown_product')


-- ============================================================================
-- 4. table: bronze.orders profiling
-- ============================================================================

select 
    count(*) as total_orders,
    min(created_at) as earliest_order,
    max(created_at) as latest_order,
    count(distinct user_id) as unique_ordering_users,
    count(distinct website_session_id) as unique_sessions,
    min(price_usd) as min_price,
    max(price_usd) as max_price,
    min(cogs_usd) as min_cogs,
    max(cogs_usd) as max_cogs,
    min(items_purchased) as min_items_purchased,
    max(items_purchased) as max_items_purchased,
    count(*) filter (where price_usd <= 0) as non_positive_price_count,
    count(*) filter (where cogs_usd <= 0) as non_positive_cogs_count,
    count(*) filter (where price_usd is null) as null_price_count,
    count(*) filter (where cogs_usd is null) as null_cogs_count,
    count(*) filter (where items_purchased <= 0) as invalid_item_count
from bronze.orders;

select 
    count(o.order_id) as total_orders,
    count(*) filter (where ws.website_session_id is null) as orphaned_order_sessions,
    count(*) filter (where p.product_id is null) as orphaned_primary_products
from bronze.orders o
left join bronze.website_sessions ws 
    on o.website_session_id = ws.website_session_id
left join bronze.products p 
    on o.primary_product_id = p.product_id;

-- remediation runbook: bronze.orders
-- failure 1: orphaned_order_sessions > 0
-- action: if foreign key constraints are enforced, create a dummy session record in silver:
--         insert into silver.website_sessions (website_session_id, created_at, user_id, is_repeat_session, traffic_channel)
--         values (-1, '1970-01-01', -1, 0, 'missing_session');
--         then update orphaned orders to link to website_session_id = -1
-- failure 2: non_positive_price_count > 0 or price_usd is null
-- action: route corrupted records to a quarantine table silver.quarantined_orders instead of breaking the pipeline
-- failure 3: orphaned_primary_products > 0
-- action: route to a default fallback product_id = -1 or coalesce with an 'unassigned' dimension record


-- ============================================================================
-- 5. table: bronze.order_items profiling and reconciliation
-- ============================================================================

select 
    count(*) as total_order_items,
    min(price_usd) as min_item_price,
    max(price_usd) as max_item_price,
    min(cogs_usd) as min_item_cogs,
    max(cogs_usd) as max_item_cogs,
    count(*) filter (where price_usd <= 0) as non_positive_price_items,
    count(*) filter (where cogs_usd <= 0) as non_positive_cogs_items,
    count(*) filter (where is_primary_item not in (0, 1)) as invalid_primary_flag,
    count(*) filter (where price_usd is null or cogs_usd is null) as null_price_cogs
from bronze.order_items;

select 
    count(oi.order_item_id) as total_items,
    count(distinct oi.order_id) as distinct_orders_in_items,
    count(*) filter (where o.order_id is null) as orphaned_order_items,
    count(*) filter (where p.product_id is null) as orphaned_item_products
from bronze.order_items oi
left join bronze.orders o 
    on oi.order_id = o.order_id
left join bronze.products p 
    on oi.product_id = p.product_id;

with item_aggregates as (
    select 
        order_id,
        count(*) as calculated_item_count,
        sum(price_usd) as calculated_total_price,
        sum(cogs_usd) as calculated_total_cogs
    from bronze.order_items
    group by order_id
)
select 
    count(*) as audited_orders,
    count(*) filter (where o.items_purchased != ia.calculated_item_count) as item_count_mismatches,
    count(*) filter (where round(o.price_usd::numeric, 2) != round(ia.calculated_total_price::numeric, 2)) as price_mismatches,
    count(*) filter (where round(o.cogs_usd::numeric, 2) != round(ia.calculated_total_cogs::numeric, 2)) as cogs_mismatches
from bronze.orders o
join item_aggregates ia 
    on o.order_id = ia.order_id;

-- remediation runbook: bronze.order_items
-- failure 1: orphaned_order_items > 0
-- action: discard or hold orphaned line items in silver.quarantined_order_items; child rows cannot exist without an order
-- failure 2: price_mismatches > 0 or item_count_mismatches > 0
-- action: treat line item grain as single source of truth; re-aggregate from order_items to update the order header total
-- failure 3: invalid_primary_flag > 0
-- action: force boolean conversion using (is_primary_item::int = 1)


-- ============================================================================
-- 6. table: bronze.order_item_refunds profiling
-- ============================================================================

select 
    count(*) as total_refunds,
    count(distinct order_item_refund_id) as distinct_refund_ids,
    count(distinct order_item_id) as distinct_refunded_items,
    count(distinct order_id) as distinct_refunded_orders,
    min(refund_amount_usd) as min_refund_amount,
    max(refund_amount_usd) as max_refund_amount,
    count(*) filter (where refund_amount_usd <= 0) as non_positive_refunds,
    count(*) filter (where refund_amount_usd is null) as null_refunds
from bronze.order_item_refunds;

select 
    count(oir.order_item_refund_id) as total_refund_records,
    count(*) filter (where oi.order_item_id is null) as orphaned_refund_items,
    count(*) filter (where o.order_id is null) as orphaned_refund_orders,
    count(*) filter (where oir.refund_amount_usd::numeric > oi.price_usd::numeric) as refunds_exceeding_item_price
from bronze.order_item_refunds oir
left join bronze.order_items oi 
    on oir.order_item_id = oi.order_item_id
left join bronze.orders o 
    on oir.order_id = o.order_id;

-- remediation runbook: bronze.order_item_refunds
-- failure 1: non_positive_refunds > 0 or null_refunds > 0
-- action: filter out zero-value refunds during insert: where refund_amount_usd > 0
-- failure 2: orphaned_refund_items > 0
-- action: quarantine records; cannot credit refunds without a valid order_item linkage
-- failure 3: refunds_exceeding_item_price > 0
-- action: cap refund amount at original item price using least(oir.refund_amount_usd, oi.price_usd)


-- ============================================================================
-- 7. table: bronze.website_pageviews profiling
-- ============================================================================

select 
    count(*) as total_pageviews,
    count(distinct website_pageview_id) as distinct_pageview_ids,
    count(distinct website_session_id) as distinct_sessions,
    count(distinct pageview_url) as distinct_urls,
    count(*) filter (where website_pageview_id is null) as null_pageview_ids,
    count(*) filter (where website_session_id is null) as null_session_ids,
    count(*) filter (where pageview_url is null or trim(pageview_url) = '') as empty_urls,
    count(wp.website_pageview_id) filter (where ws.website_session_id is null) as orphaned_pageviews
from bronze.website_pageviews wp
left join silver.website_sessions ws
    on wp.website_session_id = ws.website_session_id;

select 
    pageview_url,
    count(*) as view_count,
    round(count(*)::numeric * 100.0 / sum(count(*)) over (), 2) as traffic_share_pct
from bronze.website_pageviews
group by pageview_url
order by view_count desc;

-- remediation runbook: bronze.website_pageviews
-- failure 1: orphaned_pageviews > 0
-- action: filter out clickstream records that have no corresponding parent session:
--         where website_session_id in (select website_session_id from silver.website_sessions)
-- failure 2: empty_urls > 0
-- action: replace empty page paths with '/unknown_page' using coalesce(nullif(trim(pageview_url), ''), '/unknown_page')
