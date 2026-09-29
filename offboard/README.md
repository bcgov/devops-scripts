# Offboarding

Two read-only reports. They share no calls. A GitHub login and an OpenShift subject often look alike, and that is the only overlap.

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

The repository list, collaborator lists, CODEOWNERS files, and environment reviewers are fetched once and matched against every login. Organization members are one list per organization. Teams are one GraphQL call per organization. Code search and assignee search run in batches of six logins, which is as many as GitHub's five-`OR` limit allows. Review requests stay one query per live login, because a batched result does not say who was requested.

| Check | Source |
| --- | --- |
| Organization membership | `GET /orgs/{org}/members`, then a local match |
| Teams | One GraphQL call per organization for every live login, then a local match |
| Repository access | Collaborator permission on each target repository, marked direct or through a team or organization role |
| CODEOWNERS (checked repositories) | `@user` entries in the target repositories' CODEOWNERS file (`.github/`, root or `docs/`), comments ignored |
| Environment required reviewers | Deployment environments in the target repositories that list the user, or one of the user's teams, as a required reviewer |
| CODEOWNERS (code search) | Code search for the logins in CODEOWNERS files across the organizations |
| Assigned | Open issues and pull requests assigned to the user |
| Review requested | Open pull requests waiting on the user's review |

The target repositories are those given with `--repo` or `--repo-file`. Without either, they are the repositories in the configured organizations where you have admin (`gh api user/repos` with `permissions.admin`).

Requires `gh` (scopes `repo` and `read:org`) and `jq`.

The per-repo checks make 3 to 4 API calls per repository, about 2 seconds per repository. With around 200 admin repositories a run takes about 7 minutes, whatever the length of the login list. `--repo` or `--repo-file` narrows it. Progress goes to stderr, the report to stdout.

Limits: only what your login can see; repository access needs push access; code search hits default branches and only when `@user` is in the returned text fragment (10 requests a minute); issue search returns at most 1,000 results per query; a login on more than 100 teams is noted and the rest of that login's teams are not listed.

## `offboard-openshift.sh`

RoleBindings on the cluster your `oc` login points at. Run this on the machine where that login exists.

```bash
oc login ...
./offboard/offboard-openshift.sh [options] [github-username ...]

./offboard/offboard-openshift.sh thermcampos rmcampos --email first.last@gov.bc.ca

./offboard/offboard-openshift.sh --idir EXAMPLEIDIR --email first.last@gov.bc.ca example-user
```

| Option | Meaning |
| --- | --- |
| `--email ADDR` | Match this address as a User subject (repeatable). |
| `--idir NAME` | Also match `NAME` and `NAME@idir` (repeatable). |
| `--json` | JSON output instead of text. |

Each GitHub username is matched as that name and as `name@github`. An email is matched only as itself. Each input is its own section, and the detail line shows the subject string that matched. RoleBindings are read once per namespace. Exit codes match the GitHub script, except `3` means an `oc` call failed. `oc` not logged in is a usage error.

Requires `oc` logged in, and `jq`.

Limits: namespaces you can read; unreadable namespaces are counted in a note. Group subjects are not read.

## Tests

```bash
bats offboard/tests
```
