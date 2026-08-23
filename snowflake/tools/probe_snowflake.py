#!/usr/bin/env python3
"""
probe_snowflake.py - acceptance test for the Snowflake side.

Both must pass:
  1. key-pair auth connects, with the right role and warehouse
  2. writes are REJECTED  <- failing this is worse than failing to connect

Usage:  python snowflake/tools/probe_snowflake.py
"""
import sys

try:
    import snowflake.connector
except ImportError:
    sys.exit("missing dependency:  python -m pip install 'snowflake-connector-python[secure-local-storage]'")

CONN_NAME = "audit"
GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[90m", "\033[0m"

failed = False


def report(name, ok, detail="", hint=""):
    global failed
    tag = f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"
    print(f"{name:<34}{tag}  {DIM}{detail}{RESET}")
    if not ok:
        failed = True
        if hint:
            print(f"  {YELLOW}-> {hint}{RESET}")


print("\n=== Snowflake acceptance test ===\n")

# --- 1. connect ---
try:
    cx = snowflake.connector.connect(connection_name=CONN_NAME)
    report("key-pair connect", True)
except Exception as e:
    report("key-pair connect", False, str(e)[:160],
           "check account/user in ~/.snowflake/connections.toml, and that the public key "
           "was registered with ALTER USER ... SET RSA_PUBLIC_KEY")
    sys.exit(1)

cur = cx.cursor()

# --- 2. identity ---
cur.execute("SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE()")
user, role, wh = cur.fetchone()
report("role is AUDIT_AGENT", (role or "").upper() == "AUDIT_AGENT",
       f"user={user} role={role} wh={wh}",
       "is the role in connections.toml correct?")
report("warehouse is WH_AUDIT", (wh or "").upper() == "WH_AUDIT", f"{wh}")

# --- 3. can read ---
try:
    cur.execute("SHOW TABLES IN DATABASE PROD")
    n = len(cur.fetchall())
    report("can list tables", n > 0, f"{n} tables",
           "missing GRANT USAGE ON ALL SCHEMAS?")
except Exception as e:
    report("can list tables", False, str(e)[:160])

# --- 4. the one that matters: writes must fail ---
write_probes = [
    ("CREATE TABLE", "CREATE TABLE PROD.PUBLIC._audit_probe_should_fail (x INT)"),
    ("INSERT",       "INSERT INTO PROD.PUBLIC._audit_probe_should_fail VALUES (1)"),
    ("DROP",         "DROP TABLE IF EXISTS PROD.PUBLIC._audit_probe_should_fail"),
]
for label, sql in write_probes:
    try:
        cur.execute(sql)
        report(f"{label} rejected", False, "IT SUCCEEDED",
               "the role has too much privilege. Re-check sql/01-guardrails.sql and do NOT "
               "use the agent until this is locked down")
    except Exception as e:
        msg = str(e)
        denied = any(k in msg for k in
                     ("Insufficient privileges", "not authorized", "does not exist or not authorized"))
        report(f"{label} rejected", denied, msg[:90],
               "it errored, but not with a privilege error - check manually")

# --- 5. DMF results view ---
try:
    cur.execute("""SELECT COUNT(*) FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
                   WHERE measurement_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())""")
    (c,) = cur.fetchone()
    report("can read DMF results", True, f"{c} rows in the last 30 days"
           + ("  (no DMFs attached yet - expected)" if c == 0 else ""))
except Exception as e:
    report("can read DMF results", False, str(e)[:120],
           "missing GRANT DATABASE ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER, or the "
           "account is not Enterprise Edition (use the fallback)")

# --- 6. timeout guard ---
try:
    cur.execute("SHOW PARAMETERS LIKE 'STATEMENT_TIMEOUT_IN_SECONDS' IN WAREHOUSE WH_AUDIT")
    rows = cur.fetchall()
    val = int(rows[0][1]) if rows else -1
    report("STATEMENT_TIMEOUT set", 0 < val <= 300, f"{val}s",
           "without it, one cartesian product from the agent runs all night")
except Exception as e:
    print(f"{'STATEMENT_TIMEOUT set':<34}{YELLOW}SKIP{RESET}  {DIM}{str(e)[:80]}{RESET}")

cur.close()
cx.close()

print()
if failed:
    print(f"{RED}FAILED - do not start using the agent in this state.{RESET}")
    sys.exit(1)
print(f"{GREEN}Snowflake side OK. Next: pwsh snowflake\scripts\02-verify.ps1{RESET}")
