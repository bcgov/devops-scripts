# OpenShift & Database Utilities

Standalone CLI scripts for OpenShift operations and PostgreSQL database management.

## Scripts

### 1. `rename_deployment.sh`
Renames an OpenShift deployment by exporting its manifest, updating metadata and label selectors (`deployment=...`), deleting the old deployment, and applying the new one.

```bash
# Rename to <source>-prev by default:
./scripts/oc/rename_deployment.sh my-app-frontend

# Rename to explicit target:
./scripts/oc/rename_deployment.sh my-app-frontend my-app-frontend-v2
```

### 2. `db_transfer.sh`
Stages a binary `pg_dump` in `/tmp` in the target container so its TOC can be filtered before `pg_restore`. Automatically filters conflicting PostGIS extension objects and applies `--no-owner --no-privileges`; ensure the target has enough ephemeral storage for the dump.

```bash
./scripts/oc/db_transfer.sh <source-deployment> <target-deployment>

# Example:
./scripts/oc/db_transfer.sh my-app-db-prev my-app-db
```

### 3. `db_compare.sh`
Compares PostgreSQL table row counts between two database deployments to verify data migration integrity.

```bash
./scripts/oc/db_compare.sh <source-deployment> <target-deployment>

# Example:
./scripts/oc/db_compare.sh my-app-db-prev my-app-db
```

### 4. `rights_reporter.sh`
Audits and reports OpenShift user roles and RBAC bindings across all projects accessible to the active `oc` session (`oc whoami`). Analyzes role distribution and flags potential security/governance risks (e.g. projects with excess admins or missing view/edit roles).

```bash
# Default roles (admin, edit, view):
./scripts/oc/rights_reporter.sh

# Specific roles:
./scripts/oc/rights_reporter.sh "admin edit view basic-user"

# Remote execution (pin to a release tag):
curl -fsSL https://raw.githubusercontent.com/bcgov/actions-openshift/v1/scripts/oc/rights_reporter.sh | bash

# Custom roles:
curl -fsSL https://raw.githubusercontent.com/bcgov/actions-openshift/v1/scripts/oc/rights_reporter.sh | bash -s -- "admin edit"

# Redirect to a report file:
curl -fsSL https://raw.githubusercontent.com/bcgov/actions-openshift/v1/scripts/oc/rights_reporter.sh | bash -s -- "admin edit view" > report.txt 2>&1
```

## Example: Postgres Database Migration

These scripts can migrate a postgres or postgis database.

Make sure your template deploys the correct db version. PR-based pipelines often require a merge before custom images are re-labeled.

```bash
# 1. Scale down or delete stack (non-db only)
# Use web console or cli

# 2. Rename the old db (`-prev` auto-appended)
./scripts/oc/rename_deployment.sh your-db

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
./scripts/oc/db_transfer.sh your-db-prev your-db

# 6. Collation Refresh (PostgreSQL Major Upgrade / glibc update)
# When upgrading PostgreSQL major versions, clear the collation version warning:
# oc exec -it deployment/your-db -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "ALTER DATABASE ${POSTGRES_DB} REFRESH COLLATION VERSION;"

# 7. Compare row counts between source and target databases
./scripts/oc/db_compare.sh your-db-prev your-db

# 8. Scale up stack or recreate deployments
# Use web console, GitHub Actions workflow or cli
```

## Prerequisites
- Active OpenShift CLI session (`oc whoami`)
- `jq` installed locally
- `bc` installed locally (for `rights_reporter.sh` ratio calculations)
