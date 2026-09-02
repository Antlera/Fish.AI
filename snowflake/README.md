# snowflake/ - read-only Snowflake auditing (optional, 🚧 TODO)

> **Status: unfinished.** Nothing here is enabled by default - `setup.ps1` does not touch
> this directory and the default OpenCode config has no MCP entry. More importantly, the
> chain has **never been verified against a live Snowflake account**:
>
> | Piece | Status |
> |---|---|
> | `sql/01-guardrails.sql`, `sql/02-dmf-examples.sql` | written, never executed for real |
> | `tools/gen-keypair.ps1` | works |
> | `scripts/01-install-mcp.ps1` | works up to the connection attempt |
> | `tools/probe_snowflake.py` | **never passed** - needs a real account |
> | agent -> MCP -> Snowflake round trip | **untested** |
>
> Treat this as a starting point to finish, not a feature to rely on.

Lets the agent query a production Snowflake account through a role that **cannot write**.
Completely independent of the local-file workflow; skip this entire directory if you do
not need it.

## The security model

The real boundary is Snowflake RBAC, not anything on this machine:

| Layer | What it stops | Can it be bypassed? |
|---|---|---|
| `AGENTS.md` | the agent choosing to read raw rows | yes - it is a prompt |
| `service_config.yaml` | write statements, rejected client-side | yes - it is a client config |
| **`AUDIT_AGENT` role grants** | **anything but USAGE and SELECT** | **no** |
| Resource monitor | runaway credit spend | no |

Client-side layers exist so mistakes fail fast and locally. Do not rely on them.
`probe_snowflake.py` fails loudly if writes are *not* rejected - that check is the point.

## Setup

Three of these steps need a Snowflake account you administer; they cannot be automated
from here.

```powershell
pwsh snowflake\scripts\01-install-mcp.ps1
```

Installs uv + snowflake-labs-mcp and merges the MCP block into `app\workspace\opencode.json`
(Fish.AI's project-level OpenCode config).
Then:

1. **Run `sql\01-guardrails.sql` as ACCOUNTADMIN.** Edit the `-- CONFIGURE:` lines at the
   top first (database name, credit quota). This creates the warehouse, resource monitor,
   read-only role and service user.

2. **Generate keys and register the public one:**

   ```powershell
   pwsh snowflake\tools\gen-keypair.ps1
   ```

   Prints (and copies) the `ALTER USER ... SET RSA_PUBLIC_KEY` statement to run in
   Snowflake. The private key stays in `~\.snowflake\keys\` with a tightened ACL.

3. **Fill in `%USERPROFILE%\.snowflake\connections.toml`** - the `account` identifier is
   `<orgname>-<account_name>`, with no `.snowflakecomputing.com` suffix.

## Verify

```powershell
python snowflake\tools\probe_snowflake.py
```

**Both** conditions must hold: the connection works, *and* CREATE / INSERT / DROP are all
rejected. If the write-rejection check fails, stop - the role has too much privilege.

```powershell
pwsh snowflake\scripts\02-verify.ps1
```

End-to-end: inference up, MCP server starts, connections.toml actually filled in,
OpenCode config valid.

## Using it

Copy `AGENTS.md` from this directory into your audit working directory (it is a different
ruleset from `app/workspace/AGENTS.md` - it forbids reading raw business data), then run
`opencode` there.

The intended loop:

> agent reads schema and proposes checks -> **you review** -> you attach the DMFs ->
> Snowflake runs them on a schedule -> the agent only looks at failing rows in
> `DATA_QUALITY_MONITORING_RESULTS`

The agent deliberately cannot attach DMFs itself: that needs `ALTER TABLE`, which the role
does not have. That is the design, not a limitation.

## Contents

```
scripts/01-install-mcp.ps1    install the MCP server, wire into OpenCode
scripts/02-verify.ps1         end-to-end check
scripts/03-lockdown.ps1       optional: observe (and optionally restrict) outbound traffic
sql/01-guardrails.sql         warehouse, resource monitor, read-only role  [ACCOUNTADMIN]
sql/02-dmf-examples.sql       data metric function examples and the audit loop
config/connections.toml       template - copied to ~\.snowflake\
config/service_config.yaml    MCP SQL permission list
tools/gen-keypair.ps1         RSA key pair for key-pair auth
tools/probe_snowflake.py      acceptance test; fails if writes are not rejected
AGENTS.md                     agent behaviour rules for audit work
```

Failure modes are listed in [../TROUBLESHOOTING.md](../TROUBLESHOOTING.md).
