# Offboarding

`offboard.sh` runs both reports, one block per person. The two scripts underneath share no calls. By default, queries all distinct authenticated OpenShift clusters in kubeconfig (e.g. Silver and Gold).

```bash
./offboard/offboard.sh
# asks for people

./offboard/offboard.sh \
  gpascucci=greg.pascucci \
  ianliuwk1019 \
  franTarkenton \
  DBAJohnL \
  Mitchiavelli \
  MCatherine1994 \
  thermcampos \
  rmcampos

# Limit OpenShift discovery to active cluster context:
./offboard/offboard.sh -c gpascucci=greg.pascucci

# Target a specific OpenShift context directly:
./offboard/offboard.sh --context gold-ctx gpascucci=greg.pascucci
```

Names joined with `=` belong to one person. Each name is searched for as written. An OpenShift subject matches when it contains the name. No suffix is added. A name that is a valid GitHub login is also sent to the GitHub audit. If `oc` is not logged in, the GitHub blocks are still printed and OpenShift is skipped. Pass `--org-owner` to include GitHub org and team DELETE commands. Pass `-c` or `--current-cluster` to limit OpenShift discovery to the active cluster context, or `--context <name>` to target a specific context. Pass `-C` or `--all-clusters` for multi-cluster (default).

## `offboard-github.sh`

GitHub access and ownership, using your own `gh` login.

```bash
./offboard/offboard-github.sh [options] <github-username> [more usernames]

./offboard/offboard-github.sh example-user

./offboard/offboard-github.sh --json --org=bcgov,bcgov-c \
  --repo bcgov/example-repo --repo bcgov/another-repo example-user

./offboard/offboard-github.sh --repo-file repos.txt \
  ianliuwk1019 franTarkenton DBAJohnL Mitchiavelli gpascucci MCatherine1994 thermcampos rmcampos
```

| Option | Meaning |
| --- | --- |
| `--org ORG` | Organizations to check (repeatable, comma-separated). `--org=bcgov,bcgov-c` is valid. Default: `OFFBOARD_ORGS` (space- or comma-separated), else `bcgov` and `bcgov-c`. |
| `--org-owner` | Include org and team DELETE commands (needs an org owner or team admin). Default: omit those commands. Membership is still listed. |
| `--repo OWNER/NAME` | Repository for the per-repo checks (repeatable). |
| `--repo-file FILE` | File with one `OWNER/NAME` per line. |
| `--json` | JSON output instead of text. |

Each finding may include a cleanup command in JSON. In text output, notes that are only `#` lines stay under the finding. Commands that can be run (`gh`, `oc`, the environment helper) are printed again at column 0 after that person, so they paste into a shell and into bash history. The audit does not run them. Org and team DELETE commands are omitted unless `--org-owner` is set. Direct collaborator deletes and `github-drop-env-reviewer.sh` need repository admin. GitHub has no per-reviewer delete; the helper PUTs the remaining required-reviewer list.

Login, organization, team, and CODEOWNERS comparisons are case-insensitive.

The repository list, collaborator lists, and CODEOWNERS files are fetched once and matched against every login. Organization members are one list per organization. Teams are one GraphQL call per organization. CODEOWNERS code search is one query per live login.

| Check | Source |
| --- | --- |
| Organization membership | `GET /orgs/{org}/members`, then a local match |
| Teams | One GraphQL call per organization for every live login, then a local match |
| Repository access | Collaborator permission on each target repository, marked direct or through a team or organization role |
| CODEOWNERS | CODEOWNERS files in the target repositories that mention `@user`. Listed as `OWNER/REPO: path`. The matching line is not printed. |
| CODEOWNERS (code search) | The same list for CODEOWNERS files across the organizations, including repositories you do not admin. A file already listed above is not repeated. |
| Environment required reviewers | People listed on a repository environment protection rule. A team on that rule is not listed here. |

The target repositories are those given with `--repo` or `--repo-file`. Without either, they are the repositories in the configured organizations where you have admin (`gh api user/repos` with `permissions.admin`).

Requires `gh` (scopes `repo` and `read:org`) and `jq`.

The per-repo checks make 3 to 4 API calls per repository, about 2 seconds per repository. With around 200 admin repositories a run takes several minutes, whatever the length of the login list. `--repo` or `--repo-file` narrows it. Progress goes to stderr, the report to stdout.

Limits: only what your login can see; repository access needs push access; code search is one query per live login (10 requests a minute) and only matches when `@user` is in the returned text fragment; a login on more than 100 teams is noted and the rest of that login's teams are not listed.

## `offboard-openshift.sh`

RoleBindings across distinct authenticated OpenShift clusters in your kubeconfig (e.g. Silver and Gold). Run this on the machine where those logins exist.

```bash
# Query all distinct authenticated clusters in kubeconfig (default):
./offboard/offboard-openshift.sh --name thermcampos --name rmcampos --name greg.pascucci

# Limit discovery to only the active cluster context:
./offboard/offboard-openshift.sh -c --name greg.pascucci

# Target a specific kubeconfig context directly:
./offboard/offboard-openshift.sh --context gold-ctx --name greg.pascucci
```

| Option | Meaning |
| --- | --- |
| `--name STRING` | Name to search for (repeatable). A User subject matches when it contains the name. |
| `-c`, `--current-cluster` | Query only the active cluster context (default queries all authenticated clusters in kubeconfig). |
| `--context <name>` | Target a specific kubeconfig context directly. |
| `-C`, `--all-clusters` | Query all distinct authenticated clusters in kubeconfig (default behavior). |
| `--json` | JSON output instead of text. |

Matching ignores case. No suffix is added. Each name is its own section, and the detail line is `binding -> role` (with `[cluster]` prepended in multi-cluster runs). The `oc` command is printed at column 0 after that name (including `--context <name>` when targeting non-default or specific contexts); the audit does not run it. RoleBindings are read once per namespace. Exit codes match the GitHub script, except `3` means an `oc` call failed. `oc` not logged in is a usage error. Multi-cluster mode gracefully skips unreachable or unauthenticated clusters with a warning to stderr.

Requires `oc` logged in, and `jq`.

Limits: namespaces you can read; unreadable namespaces are counted in a note. Group subjects are not read.

## Tests

```bash
bats offboard/tests
```
