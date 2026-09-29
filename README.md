# devops-scripts

Scripts a person runs from a workstation with their own login (for example an active `oc login` session). Scripts called by GitHub Actions live in the action repositories instead.

## Scripts

### Certificates ([`cert/`](cert))

- [`csr_generator.sh`](cert/csr_generator.sh): generate a private key and certificate signing request (CSR) for an OpenShift Route.
- [`install_cert.sh`](cert/install_cert.sh): apply an edge Route with a custom TLS certificate, key and issuing CA.

### OpenShift and databases ([`oc/`](oc))

- [`rename_deployment.sh`](oc/rename_deployment.sh): rename a deployment and its `deployment=` label selectors, restoring the original on failure.
- [`oc_rename.sh`](oc/oc_rename.sh): rename an object of any type (deployment, statefulset, daemonset, replicaset or other), updating the matching label selector for workload types.
- [`db_transfer.sh`](oc/db_transfer.sh): stream a `pg_dump` from one database deployment and restore it into another with `pg_restore`.
- [`db_compare.sh`](oc/db_compare.sh): compare PostgreSQL table row counts between two database deployments.
- [`rights_reporter.sh`](oc/rights_reporter.sh): report user role bindings and risk indicators across accessible namespaces.
- Postgres migration walkthrough: [`oc/README.md`](oc/README.md)

### Offboarding ([`offboard/`](offboard))

- [`offboard-audit.sh`](offboard/offboard-audit.sh): read-only report of where a departed person still has GitHub or OpenShift access or ownership.

## Checks

Pull requests and pushes to `main` run `shellcheck --severity=warning` on every `*.sh` file and the `*.bats` tests.
