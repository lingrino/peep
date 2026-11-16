-- Monthly revenue per customer, top 10.
WITH monthly AS (
    SELECT c.id,
           c.name,
           date_trunc('month', o.created_at) AS month,
           SUM(o.total) AS revenue
    FROM customers c
    JOIN orders o ON o.customer_id = c.id
    WHERE o.status = 'paid'
      AND o.created_at >= NOW() - INTERVAL '1 year'
    GROUP BY c.id, c.name, month
)
SELECT name, month, revenue,
       RANK() OVER (PARTITION BY month ORDER BY revenue DESC) AS rank
FROM monthly
ORDER BY month DESC, rank
LIMIT 10;
