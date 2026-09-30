#!/usr/bin/env bats
# Tests for offboard-github.sh with stubbed gh on PATH. No network access.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../offboard-github.sh"
  export FIXTURES="${BATS_TEST_TMPDIR}/fx"
  export STUB_LOG="${BATS_TEST_TMPDIR}/calls.log"
  mkdir -p "$FIXTURES"
  : > "$STUB_LOG"
  PATH="${BATS_TEST_DIRNAME}/stubs:${PATH}"
  export PATH
  export OFFBOARD_ORGS="example-org"
  unset OC_WHOAMI_RC GH_AUTH_RC GH_FAIL_MATCH
}

# A user with access in every GitHub check
seed_findings() {
  printf 'example-org\n' > "$FIXTURES/member-orgs"
  printf 'team-a\n' > "$FIXTURES/teams-example-org"
  printf 'example-org/repo-one\nother-org/repo-two\n' > "$FIXTURES/user-repos"
  printf 'example-user\twrite\nexample-admin\tadmin\n' > "$FIXTURES/collab-all-repo-one"
  printf 'example-user\n' > "$FIXTURES/collab-direct-repo-one"
  printf '# @example-user in a comment\n*  @example-admin @example-user\n/docs/ @example-user-two\n' > "$FIXTURES/codeowners-repo-one"
}

@test "no arguments is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"at least one GitHub username"* ]]
}

@test "unknown option is a usage error" {
  run "$SCRIPT" --bogus example-user
  [ "$status" -eq 2 ]
}

@test "invalid username is a usage error" {
  run "$SCRIPT" 'bad;name'
  [ "$status" -eq 2 ]
}

@test "missing jq is a dependency error" {
  nojq="${BATS_TEST_TMPDIR}/nojq"
  mkdir -p "$nojq"
  ln -s "${BATS_TEST_DIRNAME}/stubs/gh" "$nojq/gh"
  PATH="$nojq" run "$BASH" "$SCRIPT" example-user
  [ "$status" -eq 2 ]
  [[ "$output" == *"jq is required"* ]]
}

@test "gh not logged in is a dependency error" {
  GH_AUTH_RC=1 run "$SCRIPT" example-user
  [ "$status" -eq 2 ]
  [[ "$output" == *"not logged in"* ]]
}

@test "unknown GitHub user is skipped and the other checks do not run" {
  run "$SCRIPT" missing-user
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub account not found"* ]]
  [[ "$output" == *"Skipped, no GitHub account:"* ]]
  [[ "$output" == *"missing-user"* ]]
  run grep -c 'user/repos' "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "nothing found exits 0" {
  printf 'example-org/repo-one\n' > "$FIXTURES/user-repos"
  printf 'example-admin\tadmin\n' > "$FIXTURES/collab-all-repo-one"
  run "$SCRIPT" example-user
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing found"* ]]
  [[ "$output" != *"OpenShift"* ]]
}

@test "findings in every GitHub check exit 1 (json)" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json example-user
  [ "$status" -eq 1 ]
  counts="$(echo "$output" | jq -c '.users[0].findings | group_by(.check) | map({(.[0].check): length}) | add')"
  [ "$counts" = '{"codeowners":1,"org-membership":1,"repo-collaborator":1,"team":1}' ]
  [ "$(echo "$output" | jq -r '.repos_checked')" = 1 ]
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "repo-collaborator" and .detail == "write (direct)")'
  [ "$(echo "$output" | jq '[.users[0].findings[] | select(.detail | test("example-user-two"))] | length')" = 0 ]
}

@test "text output groups findings by user and check" {
  seed_findings
  run --separate-stderr "$SCRIPT" example-user
  [ "$status" -eq 1 ]
  [[ "$output" == *"== example-user"* ]]
  [[ "$output" == *"Repository access"* ]]
  [[ "$output" == *"example-org/repo-one: write (direct)"* ]]
  [[ "$output" != *"Environment required reviewers"* ]]
  [[ "$output" != *"CODEOWNERS (code search)"* ]]
  [[ "$output" != *"Open issues and pull requests assigned"* ]]
}

@test "--repo and --repo-file replace the default repo set" {
  seed_findings
  printf '# comment\nexample-org/repo-five\n\n' > "${BATS_TEST_TMPDIR}/repos.txt"
  run --separate-stderr "$SCRIPT" --json --repo example-org/repo-one --repo-file "${BATS_TEST_TMPDIR}/repos.txt" example-user
  [ "$(echo "$output" | jq -r '.repos_checked')" = 2 ]
  echo "$output" | jq -e '.notes[] | select(test("repo-five: collaborators not checked"))'
  run grep -c 'user/repos' "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "--org overrides OFFBOARD_ORGS" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json --org other-org example-user
  [ "$(echo "$output" | jq -c '.orgs')" = '["other-org"]' ]
  grep -q 'orgs/other-org/members' "$STUB_LOG"
  run grep -c 'orgs/example-org/members' "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "only read-only GitHub calls are made" {
  seed_findings
  run "$SCRIPT" --json example-user
  [ -z "$(grep -E -- '-X (POST|PUT|PATCH|DELETE)|--method|--input|-F ' "$STUB_LOG")" ]
  [ -z "$(grep -E '^gh api' "$STUB_LOG" | grep -E -- ' -f ' | grep -vE 'graphql|-X GET')" ]
  [ -z "$(grep '^oc ' "$STUB_LOG" || true)" ]
}

@test "live logins share one fetch and a missing login is skipped" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json example-user example-user-two missing-user
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -c '.skipped')" = '["missing-user"]' ]
  [ "$(echo "$output" | jq '[.users[] | select(.user == "example-user") | .findings[] | select(.check == "org-membership")] | length')" = 1 ]
  [ "$(echo "$output" | jq '[.users[] | select(.user == "example-user-two") | .findings[] | select(.check == "team")] | length')" = 0 ]
  [ "$(echo "$output" | jq '[.users[] | select(.user == "missing-user") | .findings[]] | length')" = 0 ]
  run grep -Fc 'members?per_page' "$STUB_LOG"
  [ "$output" = 1 ]
  run grep -c 'userLogins:' "$STUB_LOG"
  [ "$output" = 1 ]
  [ -z "$(grep 'search/' "$STUB_LOG" || true)" ]
  run grep -c 'userLogins:\["missing-user"\]' "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "matching is case insensitive" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json Example-User
  [ "$status" -eq 1 ]
  counts="$(echo "$output" | jq -c '.users[0].findings | group_by(.check) | map({(.[0].check): length}) | add')"
  [ "$counts" = '{"codeowners":1,"org-membership":1,"repo-collaborator":1,"team":1}' ]
  grep -q 'userLogins:\["example-user"\]' "$STUB_LOG"
}

@test "an API failure exits 3" {
  seed_findings
  GH_FAIL_MATCH='CODEOWNERS' run "$SCRIPT" example-user
  [ "$status" -eq 3 ]
  [[ "$output" == *"HTTP 500"* ]]
}
