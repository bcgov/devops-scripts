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

- [`offboard.sh`](offboard/offboard.sh): runs both audits, one block per person (`login` or `login=othername`).
- [`offboard-github.sh`](offboard/offboard-github.sh): read-only report of GitHub access and ownership for one or more logins. Prints cleanup commands; does not run them.
- [`offboard-openshift.sh`](offboard/offboard-openshift.sh): read-only report of OpenShift RoleBindings whose user subject contains a given name.

## Checks

Pull requests and pushes to `main` run `shellcheck --severity=warning` on every `*.sh` file and the `*.bats` tests.
