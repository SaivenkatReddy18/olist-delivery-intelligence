-- ================================================================
-- Olist E-Commerce: Delivery Performance & Customer Satisfaction
-- Business Question: What is the cost of late deliveries on Olist,
-- and which states, categories, and sellers are the biggest risk?
-- Dataset: Brazilian E-Commerce Public Dataset (2016-2018)
-- ================================================================


-- ----------------------------------------------------------------
-- QUERY 1: Order Status Overview
-- What share of orders actually reached the customer?
-- ----------------------------------------------------------------
SELECT
    order_status,
    COUNT(*)                                                        AS orders,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)            AS pct
FROM orders
GROUP BY order_status
ORDER BY orders DESC;


-- ----------------------------------------------------------------
-- QUERY 2: On-Time vs Late Delivery Split
-- Core metric: what % of delivered orders arrived late?
-- ----------------------------------------------------------------
SELECT
    CASE
        WHEN order_delivered_customer_date <= order_estimated_delivery_date THEN 'On Time'
        ELSE 'Late'
    END                                                             AS delivery_status,
    COUNT(*)                                                        AS orders,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)            AS pct_of_orders
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
  AND order_estimated_delivery_date IS NOT NULL
GROUP BY delivery_status;


-- ----------------------------------------------------------------
-- QUERY 3: Delay Buckets vs Average Review Score
-- As delays grow, how fast does satisfaction drop?
-- ----------------------------------------------------------------
WITH order_delays AS (
    SELECT
        o.order_id,
        EXTRACT(DAY FROM (
            o.order_delivered_customer_date - o.order_estimated_delivery_date
        ))                                                          AS days_late,
        r.review_score
    FROM orders o
    LEFT JOIN order_reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
)
SELECT
    CASE
        WHEN days_late <= 0             THEN '1. On Time / Early'
        WHEN days_late BETWEEN 1 AND 3  THEN '2. 1-3 days late'
        WHEN days_late BETWEEN 4 AND 7  THEN '3. 4-7 days late'
        WHEN days_late BETWEEN 8 AND 14 THEN '4. 8-14 days late'
        ELSE                                 '5. 15+ days late'
    END                                                             AS delay_bucket,
    COUNT(*)                                                        AS orders,
    ROUND(AVG(review_score), 2)                                    AS avg_review_score,
    ROUND(AVG(days_late), 1)                                       AS avg_days_late
FROM order_delays
GROUP BY delay_bucket
ORDER BY delay_bucket;


-- ----------------------------------------------------------------
-- QUERY 4: Business Impact — GMV and Review Score by Delivery Status
-- What share of revenue is tied to late orders?
-- ----------------------------------------------------------------
WITH order_base AS (
    SELECT
        o.order_id,
        CASE
            WHEN o.order_delivered_customer_date <= o.order_estimated_delivery_date THEN 'On Time'
            ELSE 'Late'
        END                                                         AS delivery_status,
        r.review_score,
        SUM(oi.price + oi.freight_value)                           AS order_gmv
    FROM orders o
    JOIN  order_items oi  ON o.order_id = oi.order_id
    LEFT JOIN order_reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
    GROUP BY o.order_id,
             o.order_delivered_customer_date,
             o.order_estimated_delivery_date,
             r.review_score
)
SELECT
    delivery_status,
    COUNT(*)                                                        AS orders,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)            AS pct_of_orders,
    ROUND(SUM(order_gmv), 2)                                       AS total_gmv,
    ROUND(SUM(order_gmv) * 100.0 / SUM(SUM(order_gmv)) OVER (), 2) AS pct_of_gmv,
    ROUND(AVG(review_score), 2)                                    AS avg_review_score,
    ROUND(AVG(order_gmv), 2)                                       AS avg_order_value
FROM order_base
GROUP BY delivery_status;


-- ----------------------------------------------------------------
-- QUERY 5: Late Delivery Rate by Customer State
-- Which regions of Brazil suffer the most? (feeds the map)
-- ----------------------------------------------------------------
SELECT
    c.customer_state,
    COUNT(*)                                                        AS total_orders,
    SUM(CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN 1 ELSE 0 END)                                         AS late_orders,
    ROUND(SUM(CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2)                 AS late_rate_pct,
    ROUND(AVG(r.review_score), 2)                                  AS avg_review_score,
    ROUND(AVG(EXTRACT(DAY FROM (
        o.order_delivered_customer_date - o.order_estimated_delivery_date
    ))), 1)                                                         AS avg_delay_days
FROM orders o
JOIN  customers c     ON o.customer_id  = c.customer_id
LEFT JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_estimated_delivery_date IS NOT NULL
GROUP BY c.customer_state
HAVING COUNT(*) >= 100
ORDER BY late_rate_pct DESC;


-- ----------------------------------------------------------------
-- QUERY 6: Late Rate and Review Score Drop by Product Category
-- Which categories are both high-risk AND hurt most when late?
-- Note: one order can contain items from multiple categories;
--       this counts at the order-item level intentionally.
-- ----------------------------------------------------------------
SELECT
    COALESCE(t.product_category_name_english,
             p.product_category_name)                               AS category,
    COUNT(DISTINCT o.order_id)                                      AS total_orders,
    ROUND(SUM(CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN 1 ELSE 0 END) * 100.0 / COUNT(DISTINCT o.order_id), 2) AS late_rate_pct,
    ROUND(AVG(CASE
        WHEN o.order_delivered_customer_date <= o.order_estimated_delivery_date
        THEN r.review_score END), 2)                               AS avg_score_ontime,
    ROUND(AVG(CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN r.review_score END), 2)                               AS avg_score_late,
    ROUND(
        AVG(CASE WHEN o.order_delivered_customer_date <= o.order_estimated_delivery_date
                 THEN r.review_score END)
      - AVG(CASE WHEN o.order_delivered_customer_date >  o.order_estimated_delivery_date
                 THEN r.review_score END), 2)                      AS score_drop
FROM orders o
JOIN  order_items oi  ON o.order_id      = oi.order_id
JOIN  products p      ON oi.product_id   = p.product_id
LEFT JOIN product_category_name_translation t
                      ON p.product_category_name = t.product_category_name
LEFT JOIN order_reviews r ON o.order_id  = r.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_estimated_delivery_date IS NOT NULL
  AND p.product_category_name IS NOT NULL
GROUP BY COALESCE(t.product_category_name_english, p.product_category_name)
HAVING COUNT(DISTINCT o.order_id) >= 100
ORDER BY late_rate_pct DESC
LIMIT 20;


-- ----------------------------------------------------------------
-- QUERY 7: Monthly Trend — Late Rate and Avg Review Score
-- Did delivery performance improve or worsen as Olist scaled?
-- (Excludes 2016 — too few orders for meaningful monthly trend)
-- ----------------------------------------------------------------
SELECT
    DATE_TRUNC('month', o.order_purchase_timestamp)                AS month,
    COUNT(*)                                                        AS total_orders,
    SUM(CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN 1 ELSE 0 END)                                         AS late_orders,
    ROUND(SUM(CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2)                 AS late_rate_pct,
    ROUND(AVG(r.review_score), 2)                                  AS avg_review_score
FROM orders o
LEFT JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_estimated_delivery_date IS NOT NULL
  AND o.order_purchase_timestamp >= '2017-01-01'
GROUP BY DATE_TRUNC('month', o.order_purchase_timestamp)
ORDER BY month;


-- ----------------------------------------------------------------
-- QUERY 8: Seller Risk Table
-- Which sellers combine high revenue with high late rates?
-- (Min 30 orders to exclude micro-sellers with noisy stats)
-- ----------------------------------------------------------------
SELECT
    oi.seller_id,
    s.seller_state,
    COUNT(DISTINCT o.order_id)                                      AS total_orders,
    ROUND(SUM(oi.price), 2)                                        AS total_revenue,
    ROUND(SUM(CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN 1 ELSE 0 END) * 100.0 / COUNT(DISTINCT o.order_id), 2) AS late_rate_pct,
    ROUND(AVG(r.review_score), 2)                                  AS avg_review_score
FROM orders o
JOIN  order_items oi  ON o.order_id  = oi.order_id
JOIN  sellers s       ON oi.seller_id = s.seller_id
LEFT JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_estimated_delivery_date IS NOT NULL
GROUP BY oi.seller_id, s.seller_state
HAVING COUNT(DISTINCT o.order_id) >= 30
ORDER BY late_rate_pct DESC
LIMIT 30;
