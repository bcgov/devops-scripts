# Offboarding

`offboard.sh` runs both reports, one block per person. The two scripts underneath share no calls.

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
```

Names joined with `=` belong to one person. Each name is searched for as written. An OpenShift subject matches when it contains the name. No suffix is added. A name that is a valid GitHub login is also sent to the GitHub audit. If `oc` is not logged in, the GitHub blocks are still printed and OpenShift is skipped.

## `offboard-github.sh`

GitHub access and ownership, using your own `gh` login.

```bash
./offboard/offboard-github.sh [options] <github-username> [more usernames]

./offboard/offboard-github.sh example-user

./offboard/offboard-github.sh --json --org bcgov \
  --repo bcgov/example-repo --repo bcgov/another-repo example-user

./offboard/offboard-github.sh --repo-file repos.txt \
  ianliuwk1019 franTarkenton DBAJohnL Mitchiavelli gpascucci MCatherine1994 thermcampos rmcampos
```

| Option | Meaning |
| --- | --- |
| `--org ORG` | Organization to check (repeatable). Default: `OFFBOARD_ORGS` (space- or comma-separated), else `bcgov bcgov-c bcgov-nr`. |
| `--repo OWNER/NAME` | Repository for the per-repo checks (repeatable). |
| `--repo-file FILE` | File with one `OWNER/NAME` per line. |
| `--json` | JSON output instead of text. |

A login GitHub does not have is printed under that name and again under `Skipped, no GitHub account`. It is not sent to GitHub. The other logins still run. Exit codes: `0` nothing found, `1` access found, `2` usage or dependency error, `3` a GitHub API call failed.

Login, organization, team, and CODEOWNERS comparisons are case-insensitive.

The repository list, collaborator lists, and CODEOWNERS files are fetched once and matched against every login. Organization members are one list per organization. Teams are one GraphQL call per organization.

| Check | Source |
| --- | --- |
| Organization membership | `GET /orgs/{org}/members`, then a local match |
| Teams | One GraphQL call per organization for every live login, then a local match |
| Repository access | Collaborator permission on each target repository, marked direct or through a team or organization role |
| CODEOWNERS | `@user` entries in the target repositories' CODEOWNERS file (`.github/`, root or `docs/`), comments ignored |

The target repositories are those given with `--repo` or `--repo-file`. Without either, they are the repositories in the configured organizations where you have admin (`gh api user/repos` with `permissions.admin`).

Requires `gh` (scopes `repo` and `read:org`) and `jq`.

The per-repo checks make 2 to 3 API calls per repository, about 2 seconds per repository. With around 200 admin repositories a run takes several minutes, whatever the length of the login list. `--repo` or `--repo-file` narrows it. Progress goes to stderr, the report to stdout.

Limits: only what your login can see; repository access needs push access; a login on more than 100 teams is noted and the rest of that login's teams are not listed.

## `offboard-openshift.sh`

RoleBindings on the cluster your `oc` login points at. Run this on the machine where that login exists.

```bash
oc login ...
./offboard/offboard-openshift.sh --name thermcampos --name rmcampos --name greg.pascucci
```

| Option | Meaning |
| --- | --- |
| `--name STRING` | Name to search for (repeatable). A User subject matches when it contains the name. |
| `--json` | JSON output instead of text. |

Matching ignores case. No suffix is added. Each name is its own section, and the detail line shows the subject string that matched. RoleBindings are read once per namespace. Exit codes match the GitHub script, except `3` means an `oc` call failed. `oc` not logged in is a usage error.

Requires `oc` logged in, and `jq`.

Limits: namespaces you can read; unreadable namespaces are counted in a note. Group subjects are not read.

## Tests

```bash
bats offboard/tests
```
