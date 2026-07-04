-- ============================================================================
-- Cartwheel & Co. -- SQL analytics showcase
-- ============================================================================
-- 15 queries against retail.db, ordered from foundational to advanced.
-- Run the whole file:   sqlite3 retail.db ".read queries.sql"
-- (or paste individual queries into any SQLite client)
--
-- Conventions:
--   * "Revenue" always means completed orders only (returned and cancelled
--     orders are excluded). Line revenue = quantity * unit_price, using the
--     price actually paid, not the catalog list price.
--   * Every result quoted in the interpretations comes from the seeded
--     dataset produced by generate_data.py, so they reproduce exactly.
-- ============================================================================


-- ============================================================================
-- SECTION 1: FOUNDATIONS -- single-table aggregation and grouping
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Q1. What is the overall shape of the business?
--
-- Business question: How much have we sold, to how many customers, and what
-- does a typical order look like? (The numbers everything else is judged
-- against.)
--
-- Interpretation: $674,631 in revenue across 3,240 completed orders from
-- 1,326 distinct buyers -- an average order value of $208. AOV that high
-- relative to a mostly sub-$100 catalog hints that revenue leans on a few
-- expensive items; Q3/Q4 confirm it.
-- ----------------------------------------------------------------------------
SELECT COUNT(DISTINCT o.order_id)                                    AS completed_orders,
       COUNT(DISTINCT o.customer_id)                                 AS buyers,
       ROUND(SUM(oi.quantity * oi.unit_price), 2)                    AS revenue,
       ROUND(SUM(oi.quantity * oi.unit_price)
             / COUNT(DISTINCT o.order_id), 2)                        AS avg_order_value
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'completed';


-- ----------------------------------------------------------------------------
-- Q2. How has revenue trended month by month?
--
-- Business question: Is the store growing, and is there seasonality we should
-- plan inventory and staffing around?
--
-- Interpretation: Strong growth from launch (Feb 2023) to a peak of $64k in
-- Nov 2024, with a clear holiday spike in Nov-Dec of both years. Revenue then
-- softens through 2025 ($36.5k in Jan down to $15.8k in June) -- Q12
-- diagnoses why.
-- ----------------------------------------------------------------------------
SELECT strftime('%Y-%m', o.order_date)                AS month,
       COUNT(DISTINCT o.order_id)                     AS orders,
       ROUND(SUM(oi.quantity * oi.unit_price), 0)     AS revenue
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'completed'
GROUP BY month
ORDER BY month;


-- ----------------------------------------------------------------------------
-- Q3. Which products bring in the most money?
--
-- Business question: Where should merchandising and stock priority go?
--
-- Interpretation: The top two products -- Portable Monitor ($87.5k) and
-- Smart Mouse ($83.1k) -- together account for a quarter of all revenue.
-- Eight of the top ten are Electronics. Units and revenue tell different
-- stories: the Smart Mouse sells 446 units to the Monitor's 245, but the
-- Monitor's higher price wins on revenue.
-- ----------------------------------------------------------------------------
SELECT p.product_name,
       c.category_name,
       SUM(oi.quantity)                               AS units_sold,
       ROUND(SUM(oi.quantity * oi.unit_price), 0)     AS revenue
FROM order_items oi
JOIN orders o     ON o.order_id = oi.order_id
JOIN products p   ON p.product_id = oi.product_id
JOIN categories c ON c.category_id = p.category_id
WHERE o.status = 'completed'
GROUP BY p.product_id
ORDER BY revenue DESC
LIMIT 10;


-- ----------------------------------------------------------------------------
-- Q4. How do the six categories compare on revenue and gross profit?
--
-- Business question: Which categories actually carry the business, and does
-- profit follow revenue?
--
-- Interpretation: Electronics generates 57.7% of revenue ($389k) and an even
-- larger share of gross profit ($262k of $406k) thanks to healthy margins.
-- Beauty moves lots of units (1,612 -- second only to Electronics) but only
-- 9.6% of revenue: high-frequency, low-ticket. Office Supplies is the
-- long tail at 5.0%.
-- ----------------------------------------------------------------------------
SELECT c.category_name,
       SUM(oi.quantity)                               AS units_sold,
       ROUND(SUM(oi.quantity * oi.unit_price), 0)     AS revenue,
       ROUND(100.0 * SUM(oi.quantity * oi.unit_price)
             / (SELECT SUM(oi2.quantity * oi2.unit_price)
                FROM order_items oi2
                JOIN orders o2 ON o2.order_id = oi2.order_id
                WHERE o2.status = 'completed'), 1)    AS pct_of_revenue,
       ROUND(SUM(oi.quantity * (oi.unit_price - p.unit_cost)), 0)
                                                      AS gross_profit
FROM order_items oi
JOIN orders o     ON o.order_id = oi.order_id
JOIN products p   ON p.product_id = oi.product_id
JOIN categories c ON c.category_id = p.category_id
WHERE o.status = 'completed'
GROUP BY c.category_id
ORDER BY revenue DESC;


-- ============================================================================
-- SECTION 2: MULTI-TABLE JOINS -- combining customers, orders, and catalog
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Q5. Who are our ten most valuable customers?
--
-- Business question: Which individuals should a VIP/loyalty program court
-- first, and is there a pattern in how we acquired them?
--
-- Interpretation: Lifetime spend for the top ten runs $2.5k-$3.4k. Six of the
-- ten arrived via referral -- twice the channel's 15% share of signups --
-- an early hint of the referral pattern Q7 quantifies. Note Hassan Lewis:
-- $2.5k across only 2 orders, a big-basket buyer worth a personal touch.
-- ----------------------------------------------------------------------------
SELECT cu.first_name || ' ' || cu.last_name           AS customer,
       cu.city,
       cu.channel,
       COUNT(DISTINCT o.order_id)                     AS orders,
       ROUND(SUM(oi.quantity * oi.unit_price), 0)     AS lifetime_spend
FROM customers cu
JOIN orders o       ON o.customer_id = cu.customer_id
                   AND o.status = 'completed'
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY cu.customer_id
ORDER BY lifetime_spend DESC
LIMIT 10;


-- ----------------------------------------------------------------------------
-- Q6. How many signups never place an order, by channel?
--
-- Business question: Are we paying to acquire accounts that never convert,
-- and is any channel worse at it?
--
-- Interpretation: 9.6% of signups overall never buy. The spread across
-- channels is narrow (7.9% social to 11.9% referral), so no channel is
-- flooding the funnel with dead accounts -- the conversion problem, such as
-- it is, is uniform. A LEFT JOIN (not inner) is what makes the non-buyers
-- visible at all.
-- ----------------------------------------------------------------------------
SELECT cu.channel,
       COUNT(*)                                                    AS signups,
       SUM(CASE WHEN b.customer_id IS NULL THEN 1 ELSE 0 END)      AS never_ordered,
       ROUND(100.0 * SUM(CASE WHEN b.customer_id IS NULL THEN 1 ELSE 0 END)
             / COUNT(*), 1)                                        AS pct_never_ordered
FROM customers cu
LEFT JOIN (SELECT DISTINCT customer_id FROM orders) b
       ON b.customer_id = cu.customer_id
GROUP BY cu.channel
ORDER BY pct_never_ordered DESC;


-- ----------------------------------------------------------------------------
-- Q7. Which acquisition channel produces the most valuable customers?
--
-- Business question: If we have one more marketing dollar, which channel
-- earns it?
--
-- Interpretation: Referral customers place 3.46 orders each and generate
-- $682 of revenue per buyer -- 54% more than paid search ($442) and 34% more
-- than organic ($508). Referral is the smallest channel by signups (15%),
-- which makes it the clearest growth lever in the dataset: more fuel to the
-- referral program should out-earn more paid-search spend.
-- ----------------------------------------------------------------------------
SELECT cu.channel,
       COUNT(DISTINCT cu.customer_id)                            AS buyers,
       COUNT(DISTINCT o.order_id)                                AS orders,
       ROUND(1.0 * COUNT(DISTINCT o.order_id)
             / COUNT(DISTINCT cu.customer_id), 2)                AS orders_per_buyer,
       ROUND(SUM(oi.quantity * oi.unit_price)
             / COUNT(DISTINCT cu.customer_id), 0)                AS revenue_per_buyer
FROM customers cu
JOIN orders o       ON o.customer_id = cu.customer_id
                   AND o.status = 'completed'
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY cu.channel
ORDER BY revenue_per_buyer DESC;


-- ============================================================================
-- SECTION 3: WINDOW FUNCTIONS -- running totals, ranking, and LAG
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Q8. Cumulative revenue over time (running total)
--
-- Business question: How is revenue compounding, and when did we cross
-- meaningful milestones?
--
-- Interpretation: The store took 20 months to reach its first ~$200k
-- (May 2024) but only 7 more to double it (~$450k by Nov 2024) -- the
-- compounding effect of the 2024 growth run. Total stands at $674.6k
-- through June 2025.
-- ----------------------------------------------------------------------------
WITH monthly AS (
    SELECT strftime('%Y-%m', o.order_date)        AS month,
           SUM(oi.quantity * oi.unit_price)       AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'completed'
    GROUP BY month
)
SELECT month,
       ROUND(revenue, 0)                          AS revenue,
       ROUND(SUM(revenue) OVER (ORDER BY month), 0) AS cumulative_revenue
FROM monthly
ORDER BY month;


-- ----------------------------------------------------------------------------
-- Q9. Top 3 products inside each category (RANK ... PARTITION BY)
--
-- Business question: Category-level bestsellers -- what belongs on each
-- category's landing page?
--
-- Interpretation: Concentration varies wildly by category. In Toys & Games
-- the #1 product (Magnetic Board Game, $11.9k) out-earns #2 four to one; in
-- Beauty the top three are close ($15.6k / $12.3k / $9.8k). A single
-- "feature the #1 product" rule would work well in Toys and waste space in
-- Beauty.
-- ----------------------------------------------------------------------------
WITH product_rev AS (
    SELECT c.category_name,
           p.product_name,
           SUM(oi.quantity * oi.unit_price)       AS revenue,
           RANK() OVER (PARTITION BY c.category_name
                        ORDER BY SUM(oi.quantity * oi.unit_price) DESC) AS revenue_rank
    FROM order_items oi
    JOIN orders o     ON o.order_id = oi.order_id AND o.status = 'completed'
    JOIN products p   ON p.product_id = oi.product_id
    JOIN categories c ON c.category_id = p.category_id
    GROUP BY c.category_name, p.product_id
)
SELECT category_name,
       revenue_rank,
       product_name,
       ROUND(revenue, 0) AS revenue
FROM product_rev
WHERE revenue_rank <= 3
ORDER BY category_name, revenue_rank;


-- ----------------------------------------------------------------------------
-- Q10. Month-over-month revenue growth (LAG)
--
-- Business question: Which months actually moved the needle, up or down?
--
-- Interpretation: Early percentages are noisy (small base), but two patterns
-- are real: November spikes both years (+46.5% in 2023, +62.4% in 2024), and
-- 2025 opens with a sustained slide (-37.6% in Jan, negative most months
-- since). Growth diagnostics like this are the trigger for the new-vs-
-- returning split in Q12.
-- ----------------------------------------------------------------------------
WITH monthly AS (
    SELECT strftime('%Y-%m', o.order_date)        AS month,
           SUM(oi.quantity * oi.unit_price)       AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'completed'
    GROUP BY month
)
SELECT month,
       ROUND(revenue, 0)                          AS revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
             / LAG(revenue) OVER (ORDER BY month), 1) AS mom_growth_pct
FROM monthly
ORDER BY month;


-- ----------------------------------------------------------------------------
-- Q11. How long do customers wait between orders? (LAG within customer)
--
-- Business question: When should a win-back email fire -- after 30 days of
-- silence, 60, 90?
--
-- Interpretation: The average gap between a customer's 1st and 2nd order is
-- 75 days, and it stays in the 63-75 day band for later orders. So a
-- "we miss you" campaign at 30 days would nag customers who were coming back
-- anyway; ~90 days (one standard cycle plus slack) is the sensible trigger.
-- 836 customers made it to a 2nd order; only 150 reached a 5th.
-- ----------------------------------------------------------------------------
WITH seq AS (
    SELECT customer_id,
           order_date,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date) AS order_number,
           LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS prev_date
    FROM orders
    WHERE status = 'completed'
)
SELECT order_number,
       COUNT(*)                                                     AS customers_reaching,
       ROUND(AVG(julianday(order_date) - julianday(prev_date)), 1)  AS avg_days_since_prev
FROM seq
WHERE prev_date IS NOT NULL
  AND order_number <= 6
GROUP BY order_number;


-- ============================================================================
-- SECTION 4: CTEs AND ADVANCED ANALYSIS -- segmentation, concentration, cohorts
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Q12. New vs. returning customer revenue, by month
--
-- Business question: Is growth coming from acquiring new customers or from
-- existing customers coming back -- and which one is failing when revenue
-- falls?
--
-- Interpretation: This query explains the 2025 slowdown seen in Q2/Q10.
-- Returning-customer revenue holds up ($15k-$27k/month through 2025), but
-- new-customer revenue collapses from ~$20k/month (late 2024) to under $8k
-- by spring 2025. The returning share climbs past 74% -- healthy loyalty,
-- shrinking top-of-funnel. The problem to fix is acquisition, not churn.
-- ----------------------------------------------------------------------------
WITH firsts AS (
    SELECT customer_id, MIN(order_date) AS first_order
    FROM orders
    WHERE status = 'completed'
    GROUP BY customer_id
)
SELECT strftime('%Y-%m', o.order_date)             AS month,
       ROUND(SUM(CASE WHEN o.order_date = f.first_order
                      THEN oi.quantity * oi.unit_price ELSE 0 END), 0) AS new_customer_rev,
       ROUND(SUM(CASE WHEN o.order_date > f.first_order
                      THEN oi.quantity * oi.unit_price ELSE 0 END), 0) AS returning_rev,
       ROUND(100.0 * SUM(CASE WHEN o.order_date > f.first_order
                              THEN oi.quantity * oi.unit_price ELSE 0 END)
             / SUM(oi.quantity * oi.unit_price), 1)                    AS returning_pct
FROM orders o
JOIN firsts f       ON f.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'completed'
GROUP BY month
ORDER BY month;


-- ----------------------------------------------------------------------------
-- Q13. RFM segmentation (recency / frequency / monetary quartiles)
--
-- Business question: Split the customer base into actionable groups: who do
-- we reward, who do we win back, who do we let go?
--
-- Interpretation: 246 Champions (19% of buyers) drive 33.2% of all revenue
-- at $911 average lifetime spend -- the loyalty-program shortlist. The
-- urgent group is the 228 "Lapsing regulars": historically frequent, $763
-- average spend, 25.8% of revenue, but drifting inactive. Win-back effort
-- concentrates there, not on the 624 one-and-done customers.
-- ----------------------------------------------------------------------------
WITH spend AS (
    SELECT o.customer_id,
           MAX(o.order_date)                       AS last_order,
           COUNT(DISTINCT o.order_id)              AS frequency,
           SUM(oi.quantity * oi.unit_price)        AS monetary
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'completed'
    GROUP BY o.customer_id
),
scored AS (
    SELECT *,
           NTILE(4) OVER (ORDER BY last_order)     AS r_score,   -- 4 = most recent
           NTILE(4) OVER (ORDER BY frequency)      AS f_score,   -- 4 = most orders
           NTILE(4) OVER (ORDER BY monetary)       AS m_score    -- 4 = biggest spend
    FROM spend
)
SELECT CASE
           WHEN r_score = 4 AND f_score >= 3 THEN '1. Champions'
           WHEN r_score >= 3 AND f_score <= 2 THEN '2. Recent, low frequency'
           WHEN r_score <= 2 AND f_score >= 3 THEN '3. Lapsing regulars'
           ELSE                                    '4. Lost / one-and-done'
       END                                          AS segment,
       COUNT(*)                                     AS customers,
       ROUND(AVG(monetary), 0)                      AS avg_lifetime_spend,
       ROUND(100.0 * SUM(monetary)
             / (SELECT SUM(monetary) FROM spend), 1) AS revenue_share_pct
FROM scored
GROUP BY segment
ORDER BY segment;


-- ----------------------------------------------------------------------------
-- Q14. Revenue concentration by customer decile (Pareto check)
--
-- Business question: How dependent are we on our best customers?
--
-- Interpretation: The top 10% of buyers contribute 32.7% of revenue and the
-- top 30% contribute 66% -- softer than the textbook 80/20 rule (you need the
-- top half of customers to reach 84.7%), but concentrated enough that losing
-- a slice of the first decile would show up in the P&L immediately.
-- ----------------------------------------------------------------------------
WITH spend AS (
    SELECT o.customer_id,
           SUM(oi.quantity * oi.unit_price) AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'completed'
    GROUP BY o.customer_id
),
deciles AS (
    SELECT revenue,
           NTILE(10) OVER (ORDER BY revenue DESC) AS decile
    FROM spend
)
SELECT decile,
       COUNT(*)                                    AS customers,
       ROUND(SUM(revenue), 0)                      AS revenue,
       ROUND(100.0 * SUM(revenue)
             / (SELECT SUM(revenue) FROM spend), 1) AS pct_of_revenue,
       ROUND(100.0 * SUM(SUM(revenue)) OVER (ORDER BY decile)
             / (SELECT SUM(revenue) FROM spend), 1) AS cumulative_pct
FROM deciles
GROUP BY decile;


-- ----------------------------------------------------------------------------
-- Q15. Monthly cohort retention (repeat-purchase rate by first-purchase month)
--
-- Business question: Of the customers who bought for the first time in a
-- given month, what share came back 1, 2, 3, and 6 months later? This is
-- the cleanest read on whether the product experience earns a second
-- purchase.
--
-- Interpretation: Month-1 repeat rates hover in the 10-25% band typical of
-- non-subscription e-commerce, and interestingly month-2 often *beats*
-- month-1 (e.g. the 2024-09 cohort: 15.5% -> 31.1%) -- consistent with the
-- ~75-day reorder cycle found in Q11: many customers' second purchase simply
-- lands in the second month. The 2024-11 cohort's outlier 42.5% month-1 rate
-- is holiday shoppers returning in December. Cohorts are cut off at 2024-12
-- so every row has at least 6 months of runway.
-- ----------------------------------------------------------------------------
WITH firsts AS (
    SELECT customer_id, MIN(order_date) AS first_order
    FROM orders
    WHERE status = 'completed'
    GROUP BY customer_id
),
activity AS (
    SELECT o.customer_id,
           strftime('%Y-%m', f.first_order) AS cohort,
           (CAST(strftime('%Y', o.order_date) AS INTEGER) * 12
              + CAST(strftime('%m', o.order_date) AS INTEGER))
         - (CAST(strftime('%Y', f.first_order) AS INTEGER) * 12
              + CAST(strftime('%m', f.first_order) AS INTEGER)) AS month_offset
    FROM orders o
    JOIN firsts f ON f.customer_id = o.customer_id
    WHERE o.status = 'completed'
),
counts AS (
    SELECT cohort,
           COUNT(DISTINCT CASE WHEN month_offset = 0 THEN customer_id END) AS cohort_size,
           COUNT(DISTINCT CASE WHEN month_offset = 1 THEN customer_id END) AS m1,
           COUNT(DISTINCT CASE WHEN month_offset = 2 THEN customer_id END) AS m2,
           COUNT(DISTINCT CASE WHEN month_offset = 3 THEN customer_id END) AS m3,
           COUNT(DISTINCT CASE WHEN month_offset = 6 THEN customer_id END) AS m6
    FROM activity
    GROUP BY cohort
)
SELECT cohort,
       cohort_size,
       ROUND(100.0 * m1 / cohort_size, 1) AS m1_pct,
       ROUND(100.0 * m2 / cohort_size, 1) AS m2_pct,
       ROUND(100.0 * m3 / cohort_size, 1) AS m3_pct,
       ROUND(100.0 * m6 / cohort_size, 1) AS m6_pct
FROM counts
WHERE cohort <= '2024-12'          -- only cohorts with >= 6 months of history
ORDER BY cohort;
