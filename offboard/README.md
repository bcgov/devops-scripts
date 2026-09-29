# Offboarding

## `offboard-audit.sh`

Read-only report of every place a departed person still has access or ownership. It uses your own `gh` login, and your own `oc` login when one is active. It never changes anything and never prints tokens.

```bash
./offboard/offboard-audit.sh [options] <github-username> [more usernames]

# Default organizations and repositories
./offboard/offboard-audit.sh example-user

# JSON, one organization, two repositories
./offboard/offboard-audit.sh --json --org bcgov \
  --repo bcgov/example-repo --repo bcgov/another-repo example-user

# Repository list from a file (one OWNER/NAME per line, # comments allowed)
./offboard/offboard-audit.sh --repo-file repos.txt example-user

# Also match an IDIR name in OpenShift RoleBindings
oc login ...
./offboard/offboard-audit.sh --idir EXAMPLEIDIR example-user
```

| Option | Meaning |
| --- | --- |
| `--org ORG` | Organization to check (repeatable). Default: `OFFBOARD_ORGS` (space- or comma-separated), else `bcgov bcgov-c bcgov-nr`. |
| `--repo OWNER/NAME` | Repository for the per-repo checks (repeatable). |
| `--repo-file FILE` | File with one `OWNER/NAME` per line. |
| `--idir NAME` | Also match `NAME` and `NAME@idir` in OpenShift RoleBindings. Single username only. |
| `--json` | JSON output instead of text. |

Exit codes: `0` nothing found, `1` access found, `2` usage or dependency error, `3` a GitHub API call failed.

## Checks

| Check | Source |
| --- | --- |
| Organization membership | `GET /orgs/{org}/members/{user}` for each organization |
| Teams | Teams in each organization that you can see and that list the user |
| Repository access | Collaborator permission on each target repository, marked direct or through a team or organization role |
| CODEOWNERS (checked repositories) | `@user` entries in the target repositories' CODEOWNERS file (`.github/`, root or `docs/`), comments ignored |
| Environment required reviewers | Deployment environments in the target repositories that list the user, or one of the user's teams, as a required reviewer |
| CODEOWNERS (code search) | Code search for `@user` in CODEOWNERS files across the organizations |
| Assigned | Open issues and pull requests assigned to the user |
| Review requested | Open pull requests waiting on the user's review |
| OpenShift RoleBindings | Only when `oc whoami` succeeds: RoleBindings in the namespaces listed by `oc projects` whose `User` subjects are `user`, `user@github`, or the `--idir` name. Otherwise a skip note is printed. |

The target repositories are those given with `--repo` or `--repo-file`. Without either, they are the repositories in the configured organizations where you have admin (`gh api user/repos` with `permissions.admin`).

## Requirements

- `gh`, logged in with the `repo` and `read:org` scopes (`gh auth status` lists them; add with `gh auth refresh -s read:org`)
- `jq`
- Optional: `oc`, logged in (`oc whoami`)

## Speed

The per-repo checks make 3 to 4 API calls per repository, about 2 seconds per repository. With around 200 admin repositories a run takes about 7 minutes; `--repo` or `--repo-file` narrows it. The other checks take a few seconds per user. Progress goes to stderr, the report to stdout.

## Limits

- Only what your login can see is reported: teams you cannot see, and repositories you cannot read, are not covered.
- Repository access needs push access to the repository. Repositories given with `--repo` that you cannot push to get a note instead of a result.
- Code search covers default branches of indexed repositories, and matches only when the `@user` entry is in the returned text fragment. It is limited to 10 requests a minute; the script waits when the limit is reached.
- Issue and pull request search returns at most 1,000 results per query.
- OpenShift covers the cluster your `oc` login points at, and namespaces where you can read RoleBindings; unreadable namespaces are counted in a note. Group memberships are not expanded.

## Tests

`tests/offboard-audit.bats` runs the script against stubbed `gh` and `oc` commands in `tests/stubs/`:

```bash
bats offboard/tests
```
