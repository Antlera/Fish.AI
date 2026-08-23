/* ===========================================================================
   02-dmf-examples.sql — 审计循环的执行层。

   循环长这样，注意模型只在 ① 和 ④ 出现，两次接触的都不是业务数据：

     ① 模型（本地）  读 SHOW / DESCRIBE 的输出，产出下面这类 SQL 的草稿
     ② 你           review，删掉没意义的、补上它漏掉的业务规则
     ③ 你           用有 ALTER TABLE 权限的角色执行挂载
     ④ Snowflake    按调度自己跑，结果进 DATA_QUALITY_MONITORING_RESULTS
     ⑤ 模型（本地）  只读结果视图里 value > 0 的行，写根因假设

   agent 的角色故意没有 ALTER TABLE —— 它只能提议，不能挂载。这是设计。

   DMF 需要 Enterprise Edition。没有的话见文件末尾的降级方案。
   =========================================================================== */

USE ROLE SYSADMIN;   -- 或任何拥有目标表的角色
USE DATABASE PROD;

/* --- 系统 DMF：直接挂，不用自己写 SQL ------------------------------------ */

ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION snowflake.core.null_count ON (customer_id);

ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION snowflake.core.duplicate_count ON (order_id);

ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION snowflake.core.row_count ON ();

ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION snowflake.core.blank_count ON (email);

/* 枚举值校验：lambda 表达式 */
ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION snowflake.core.accepted_values
  ON (status) IGNORE NULLS
  WHERE status IN ('PENDING','PAID','SHIPPED','CANCELLED');

/* 外键完整性：跨表 */
ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION snowflake.core.referential_check
  ON (customer_id) REFERENCES prod.sales.customers (customer_id);

/* --- 调度 -----------------------------------------------------------------
   三选一。改调度后有约 10 分钟生效延迟，别以为没生效。               */

ALTER TABLE prod.sales.orders
  SET DATA_METRIC_SCHEDULE = 'USING CRON 0 6 * * * UTC';   -- 每天 UTC 06:00
-- SET DATA_METRIC_SCHEDULE = '60 MINUTE';                 -- 固定间隔
-- SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';        -- DML 触发（最贵）

/* --- 自定义 DMF：业务规则 --------------------------------------------------
   签名必须是 TABLE(...) 进、NUMBER 出。返回值的语义统一成
   "违规行数"，这样第 ⑤ 步一句 WHERE value > 0 就能捞出所有问题。      */

CREATE SCHEMA IF NOT EXISTS prod.governance;

CREATE OR REPLACE DATA METRIC FUNCTION prod.governance.negative_amount_count(
  t TABLE(amount NUMBER)
) RETURNS NUMBER AS
$$ SELECT COUNT(*) FROM t WHERE amount < 0 $$;

CREATE OR REPLACE DATA METRIC FUNCTION prod.governance.future_dated_count(
  t TABLE(ts TIMESTAMP_NTZ)
) RETURNS NUMBER AS
$$ SELECT COUNT(*) FROM t WHERE ts > CURRENT_TIMESTAMP() $$;

CREATE OR REPLACE DATA METRIC FUNCTION prod.governance.malformed_email_count(
  t TABLE(email VARCHAR)
) RETURNS NUMBER AS
$$ SELECT COUNT(*) FROM t
   WHERE email IS NOT NULL AND NOT RLIKE(email, '^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$') $$;

/* 挂上去 */
ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION prod.governance.negative_amount_count ON (amount);
ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION prod.governance.future_dated_count ON (created_at);
ALTER TABLE prod.sales.orders
  ADD DATA METRIC FUNCTION prod.governance.malformed_email_count ON (email);

/* --- 第 ⑤ 步：agent 唯一被允许查的东西 ------------------------------------
   注意这里没有一行业务数据 —— 只有表名、指标名、数字。            */

SELECT measurement_time,
       table_database || '.' || table_schema || '.' || table_name AS full_table,
       metric_name,
       value
FROM   SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE  value > 0
  AND  measurement_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER  BY measurement_time DESC, value DESC;

/* 趋势：某个指标是在恶化还是抖动？同样只有数字。 */
SELECT DATE_TRUNC(day, measurement_time) AS d,
       metric_name,
       MAX(value) AS worst
FROM   SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE  table_name = 'ORDERS'
  AND  measurement_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP  BY 1, 2
ORDER  BY 1 DESC, 2;

/* --- 查看某张表挂了哪些 DMF ----------------------------------------------- */

SELECT * FROM TABLE(
  INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
    REF_ENTITY_NAME   => 'prod.sales.orders',
    REF_ENTITY_DOMAIN => 'TABLE'
  )
);

/* --- 卸载 ------------------------------------------------------------------ */
-- ALTER TABLE prod.sales.orders
--   DROP DATA METRIC FUNCTION snowflake.core.null_count ON (customer_id);

/* ===========================================================================
   没有 Enterprise Edition 的降级方案

   架构完全不变，只是把"Snowflake 自己按调度跑"换成"你的 cron 跑"：

     dbt tests    —— 检查项写成 schema.yml 里的 tests，dbt test 执行
     Soda Core    —— 检查项写成 checks.yml，soda scan 执行
     纯 SQL       —— 每条检查一个 SELECT COUNT(*)，结果 INSERT 进你自己的
                     审计结果表，字段对齐 (measurement_time, table, metric, value)

   第 ⑤ 步的查询照抄，只是换个表名。模型侧完全不用改。
   =========================================================================== */
