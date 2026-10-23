# OpenShift & Database Utilities

Standalone CLI scripts for OpenShift operations and PostgreSQL database management.

## Scripts

### 1. `rename_deployment.sh`
Renames an OpenShift deployment by exporting its manifest, updating metadata and label selectors (`deployment=...`), deleting the old deployment, and applying the new one.

```bash
# Rename to <source>-prev by default:
./oc/rename_deployment.sh my-app-frontend

# Rename to explicit target:
./oc/rename_deployment.sh my-app-frontend my-app-frontend-v2
```

### 2. `db_transfer.sh`
Stages a binary `pg_dump` in `/tmp` in the target container so its TOC can be filtered before `pg_restore`. Automatically filters conflicting PostGIS extension objects and applies `--no-owner --no-privileges`; ensure the target has enough ephemeral storage for the dump.

```bash
./oc/db_transfer.sh <source-deployment> <target-deployment>

# Example:
./oc/db_transfer.sh my-app-db-prev my-app-db
```

### 3. `db_compare.sh`
Compares PostgreSQL table row counts between two database deployments to verify data migration integrity.

```bash
./oc/db_compare.sh <source-deployment> <target-deployment>

# Example:
./oc/db_compare.sh my-app-db-prev my-app-db
```

### 4. `rights_reporter.sh`
Audits and reports OpenShift user roles and RBAC bindings across all projects accessible to the active `oc` session (`oc whoami`). Analyzes role distribution and flags potential security/governance risks (e.g. projects with excess admins or missing view/edit roles).

```bash
# Default roles (admin, edit, view):
./oc/rights_reporter.sh

# Specific roles:
./oc/rights_reporter.sh "admin edit view basic-user"

# Remote execution (pin to a release tag):
curl -fsSL https://raw.githubusercontent.com/bcgov/devops-scripts/main/oc/rights_reporter.sh | bash

# Custom roles:
curl -fsSL https://raw.githubusercontent.com/bcgov/devops-scripts/main/oc/rights_reporter.sh | bash -s -- "admin edit"

# Redirect to a report file:
curl -fsSL https://raw.githubusercontent.com/bcgov/devops-scripts/main/oc/rights_reporter.sh | bash -s -- "admin edit view" > report.txt 2>&1
```

### 5. `list_routes.sh`
Queries all OpenShift namespaces accessible to the active `oc` session (`oc projects -q`), extracts all Routes with TLS termination and URL information, and outputs clean tabular, JSON, or unique URL list data. By default, filters out default cluster wildcard domains (`*.apps.*.gov.bc.ca`, `*.devops.bcgov`, `*.router.default.svc.cluster.local`, `*.cluster.local`) and unencrypted routes (`TERMINATION: None`) to isolate production vanity domains for TLS certificate monitoring and migration planning without requiring cluster-admin permissions.

```bash
# Tabular vanity route inventory across all accessible namespaces:
./oc/list_routes.sh

# Include all cluster wildcard and unencrypted HTTP routes as well:
./oc/list_routes.sh -a

# Output raw unique vanity URLs (ideal for blackbox exporter or cert monitoring rules):
./oc/list_routes.sh -u

# Output structured JSON:
./oc/list_routes.sh -j | jq .

# Remote execution (without cloning the repository):
curl -fsSL https://raw.githubusercontent.com/bcgov/devops-scripts/main/oc/list_routes.sh | bash

# Remote execution with flags:
curl -fsSL https://raw.githubusercontent.com/bcgov/devops-scripts/main/oc/list_routes.sh | bash -s -- -u
curl -fsSL https://raw.githubusercontent.com/bcgov/devops-scripts/main/oc/list_routes.sh | bash -s -- -a
curl -fsSL https://raw.githubusercontent.com/bcgov/devops-scripts/main/oc/list_routes.sh | bash -s -- -j | jq .
```

#### Options
- `-a`, `--all`: Include all routes, including default cluster wildcard domains and unencrypted (HTTP) routes.
- `-v`, `--vanity-only`: Filter out default cluster wildcard routes and unencrypted routes (`TERMINATION: None`). This is the default behavior. Cluster patterns can be overridden or extended with `CLUSTER_DOMAIN_PATTERN`.
- `-u`, `--urls-only`: Output only raw, unique URLs.
- `-j`, `--json`: Output structured JSON array.
- `-h`, `--help`: Display usage and options.

#### Sample Output

Tabular (`./oc/list_routes.sh`):
```text
NAMESPACE     NAME           TERMINATION  URL
c38e9a-prod   frontend-prod  Edge         https://service.gov.bc.ca
c38e9a-prod   api-prod       Reencrypt    https://service.gov.bc.ca/api
```

Include all cluster routes (`./oc/list_routes.sh -a`):
```text
NAMESPACE     NAME           TERMINATION  URL
c38e9a-dev    frontend-dev   Edge         https://frontend-dev.apps.silver.devops.gov.bc.ca
c38e9a-prod   frontend-prod  Edge         https://service.gov.bc.ca
c38e9a-prod   api-prod       Reencrypt    https://service.gov.bc.ca/api
```

Vanity URLs only (`./oc/list_routes.sh -u`):
```text
https://service.gov.bc.ca
https://service.gov.bc.ca/api
```

JSON (`./oc/list_routes.sh -j`):
```json
[
  {
    "namespace": "c38e9a-prod",
    "name": "frontend-prod",
    "termination": "Edge",
    "host": "service.gov.bc.ca",
    "url": "https://service.gov.bc.ca"
  }
]
```

## Example: Postgres Database Migration

These scripts can migrate a postgres or postgis database.

Make sure your template deploys the correct db version. PR-based pipelines often require a merge before custom images are re-labeled.

```bash
# 1. Scale down or delete stack (non-db only)
# Use web console or cli

# 2. Rename the old db (`-prev` auto-appended)
./oc/rename_deployment.sh your-db

# 3. Make sure old and new PVC names are different
# E.g. Append DB_VERSION in OpenShift template:
#  - kind: PersistentVolumeClaim
#    apiVersion: v1
#    metadata:
#      name: ${NAME}-${ZONE}-${COMPONENT}-${DB_VERSION}

# 4. Deploy the new db
oc process -f openshift.deploy.yml -p ZONE=test -p TAG=test \
  | oc apply -f -

# 5. Stream dump from old to new db (filters conflicting PostGIS extension objects and restores with --no-owner --no-privileges)
./oc/db_transfer.sh your-db-prev your-db

# 6. Collation Refresh (PostgreSQL Major Upgrade / glibc update)
# When upgrading PostgreSQL major versions, clear the collation version warning:
# oc exec -it deployment/your-db -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "ALTER DATABASE ${POSTGRES_DB} REFRESH COLLATION VERSION;"

# 7. Compare row counts between source and target databases
./oc/db_compare.sh your-db-prev your-db

# 8. Scale up stack or recreate deployments
# Use web console, GitHub Actions workflow or cli
```

## Prerequisites
- Active OpenShift CLI session (`oc whoami`)
- `jq` installed locally
- `bc` installed locally (for `rights_reporter.sh` ratio calculations)
