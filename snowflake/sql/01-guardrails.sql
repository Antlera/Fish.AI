/* ===========================================================================
   01-guardrails.sql — 在 Snowflake 侧建护栏。
   需要 ACCOUNTADMIN(或等价)执行。Claude Code 做不了这一步,必须人来跑。

   这个文件比本地那堆脚本重要:agent 的能力边界是这里定义的,
   不是 opencode.json 里定义的。客户端配置能被绕过,RBAC 不能。
   =========================================================================== */

-- CONFIGURE: 改成你的实际值 -------------------------------------------------
SET target_db      = 'PROD';           -- 要审计的库
SET credit_quota   = 20;               -- 每月给 agent 的 credit 上限
SET wh_name        = 'WH_AUDIT';
SET role_name      = 'AUDIT_AGENT';
SET svc_user       = 'SVC_AUDIT_AGENT';
-- ---------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

/* --- 1. 专用 warehouse -----------------------------------------------------
   XSMALL 够用:审计查询是元数据和聚合,不是大 join。
   STATEMENT_TIMEOUT 是 agent 写出笛卡尔积时的兜底,不是解法。          */

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($wh_name)
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND   = 60            -- 秒。agent 是断续使用,别让它空转
  AUTO_RESUME    = TRUE
  INITIALLY_SUSPENDED = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 120
  STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 30
  COMMENT = 'Local audit agent — isolated so its cost is attributable';

/* --- 2. Resource monitor：花超了直接停 ------------------------------------
   注意是 SUSPEND_IMMEDIATE 不是 SUSPEND：SUSPEND 会等当前查询跑完，
   而"当前查询"正是那个失控的查询。                                     */

CREATE RESOURCE MONITOR IF NOT EXISTS RM_AUDIT
  WITH CREDIT_QUOTA = $credit_quota
       FREQUENCY = MONTHLY
       START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON  75 PERCENT DO NOTIFY
           ON  90 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE IDENTIFIER($wh_name) SET RESOURCE_MONITOR = RM_AUDIT;

/* --- 3. 只读角色 -----------------------------------------------------------
   只给 SELECT 和 USAGE。没有 INSERT/UPDATE/DELETE/MERGE/TRUNCATE,
   没有 CREATE，没有 ALTER。挂 DMF 需要 ALTER TABLE —— 那是你的活，不是它的。 */

CREATE ROLE IF NOT EXISTS IDENTIFIER($role_name);

GRANT USAGE  ON WAREHOUSE IDENTIFIER($wh_name) TO ROLE IDENTIFIER($role_name);
GRANT USAGE  ON DATABASE  IDENTIFIER($target_db) TO ROLE IDENTIFIER($role_name);
GRANT USAGE  ON ALL SCHEMAS    IN DATABASE IDENTIFIER($target_db) TO ROLE IDENTIFIER($role_name);
GRANT USAGE  ON FUTURE SCHEMAS IN DATABASE IDENTIFIER($target_db) TO ROLE IDENTIFIER($role_name);
GRANT SELECT ON ALL TABLES     IN DATABASE IDENTIFIER($target_db) TO ROLE IDENTIFIER($role_name);
GRANT SELECT ON FUTURE TABLES  IN DATABASE IDENTIFIER($target_db) TO ROLE IDENTIFIER($role_name);
GRANT SELECT ON ALL VIEWS      IN DATABASE IDENTIFIER($target_db) TO ROLE IDENTIFIER($role_name);
GRANT SELECT ON FUTURE VIEWS   IN DATABASE IDENTIFIER($target_db) TO ROLE IDENTIFIER($role_name);

/* DMF 结果视图 —— agent 的主要工作对象 */
GRANT DATABASE ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER
  TO ROLE IDENTIFIER($role_name);

/* 可选：让 agent 也能审计"谁动过数据"。纯元数据，没有泄露风险。
   注意 ACCOUNT_USAGE 有最长 3 小时延迟，且查询会启动 warehouse。       */
-- GRANT DATABASE ROLE SNOWFLAKE.OBJECT_VIEWER TO ROLE IDENTIFIER($role_name);
-- GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER  TO ROLE IDENTIFIER($role_name);

/* --- 4. 服务账号 -----------------------------------------------------------
   TYPE = SERVICE：不能交互登录，只能 key-pair。没有密码可以被钓。
   RSA_PUBLIC_KEY 由 tools\gen-keypair.ps1 生成后回来填。                */

CREATE USER IF NOT EXISTS IDENTIFIER($svc_user)
  TYPE = SERVICE
  DEFAULT_ROLE      = $role_name
  DEFAULT_WAREHOUSE = $wh_name
  COMMENT = 'Local audit agent on Felix laptop';

GRANT ROLE IDENTIFIER($role_name) TO USER IDENTIFIER($svc_user);

/* QUERY_TAG 让你事后能在 QUERY_HISTORY 里精确算出 agent 花了多少 credit */
ALTER USER IDENTIFIER($svc_user) SET QUERY_TAG = 'local-audit-agent';

/* --- 5. 网络策略（推荐）---------------------------------------------------
   把这个服务账号限制在你的出口 IP。密钥泄露也用不了。
   查你的出口 IP：curl ifconfig.me                                       */

-- CREATE NETWORK POLICY IF NOT EXISTS NP_AUDIT_AGENT
--   ALLOWED_IP_LIST = ('203.0.113.45/32');
-- ALTER USER IDENTIFIER($svc_user) SET NETWORK_POLICY = 'NP_AUDIT_AGENT';

/* ===========================================================================
   6. 跑完 tools\gen-keypair.ps1 之后，回来执行这一句（把公钥贴进去）
   =========================================================================== */

-- ALTER USER IDENTIFIER($svc_user) SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqhki...';

/* --- 7. 检查成果 ---------------------------------------------------------- */

SHOW GRANTS TO ROLE IDENTIFIER($role_name);
-- 期望：只有 USAGE 和 SELECT。看到任何 INSERT/UPDATE/DELETE/OWNERSHIP 就是配错了。
