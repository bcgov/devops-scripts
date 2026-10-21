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
- [`github-drop-env-reviewer.sh`](offboard/github-drop-env-reviewer.sh): repo-admin helper to drop one login from an environment required-reviewers rule.
- [`offboard-openshift.sh`](offboard/offboard-openshift.sh): read-only report of OpenShift RoleBindings whose user subject contains a given name.

### GitHub Actions ([`github/`](github))

- [`rerun-blocked.sh`](github/rerun-blocked.sh): find failed GitHub Actions runs whose log shows a blocked connection (default: the runner could not reach the OpenShift API, `dial tcp …:6443: i/o timeout`) and rerun their failed jobs after asking.

#### Usage

```sh
# Scan every non-archived repo you can push to (last 2 days), then ask before rerunning
github/rerun-blocked.sh

# Narrow the scan
github/rerun-blocked.sh --orgs bcgov,bcgov-c --days 3
github/rerun-blocked.sh --repos bcgov/quickstart-openshift
github/rerun-blocked.sh --exclude 'bcgov/old-*'

# Match a different log line, and rerun without the prompt
github/rerun-blocked.sh --pattern 'connection reset by peer' --yes
```

It always scans first and lists what it found, then asks `N blocked runs found, rerun them? [y/N]` (default No) and reruns exactly the listed runs with `gh run rerun <id> --failed`. Without a terminal (CI, cron, a pipe) it only reports unless `--yes` is set. Only the latest run per workflow and branch is checked. Runs are skipped when they are past attempt 1, still running or waiting on approval, have a job named prod/production, or deployed their commit to a prod/production environment. Needs `gh` (logged in) and `jq`.

## Checks

Pull requests and pushes to `main` run `shellcheck --severity=warning` on every `*.sh` file and the `*.bats` tests.
