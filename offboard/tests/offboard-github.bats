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
  printf 'prod\tUser\texample-user\ntest\tTeam\tteam-a\n' > "$FIXTURES/env-repo-one"
  printf '# @example-user in a comment\n*  @example-admin @example-user\n/docs/ @example-user-two\n' > "$FIXTURES/codeowners-repo-one"
  cat > "$FIXTURES/search-code" <<'JSON'
{"items":[
 {"repository":{"full_name":"example-org/repo-three"},"path":".github/CODEOWNERS","text_matches":[{"fragment":"* @example-user"}]},
 {"repository":{"full_name":"example-org/repo-four"},"path":"CODEOWNERS","text_matches":[{"fragment":"* @example-user-two"}]}
]}
JSON
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

@test "through-team repo access has no skip command" {
  printf 'example-org/repo-one\n' > "$FIXTURES/user-repos"
  printf 'example-user\twrite\n' > "$FIXTURES/collab-all-repo-one"
  : > "$FIXTURES/collab-direct-repo-one"
  run --separate-stderr "$SCRIPT" --json example-user
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "repo-collaborator" and (.detail | test("through a team")) and .cmd == "")'
  run --separate-stderr "$SCRIPT" example-user
  [ "$status" -eq 1 ]
  [[ "$output" == *"through a team or organization role"* ]]
  [[ "$output" != *"# skip:"* ]]
}

@test "findings in every GitHub check exit 1 (json)" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json example-user
  [ "$status" -eq 1 ]
  counts="$(echo "$output" | jq -c '.users[0].findings | group_by(.check) | map({(.[0].check): length}) | add')"
  [ "$counts" = '{"codeowners":1,"codeowners-search":1,"environment-reviewer":1,"org-membership":1,"repo-collaborator":1,"team":1}' ]
  [ "$(echo "$output" | jq -r '.repos_checked')" = 1 ]
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "repo-collaborator" and .detail == "write (direct)")'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "environment-reviewer" and (.detail | test("environment prod")))'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "org-membership" and .cmd == "")'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "team" and .cmd == "")'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "repo-collaborator") | .cmd | test("gh api -X DELETE repos/example-org/repo-one/collaborators/example-user")'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "environment-reviewer") | .cmd | test("github-drop-env-reviewer.sh")'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "environment-reviewer") | .cmd | test("repo admin") | not'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "codeowners" and .detail == ".github/codeowners" and .cmd == "")'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "codeowners-search" and .target == "example-org/repo-three" and .detail == ".github/CODEOWNERS")'
  [ "$(echo "$output" | jq '[.users[0].findings[] | select(.detail | test("team-a|repo-four|example-user-two"))] | length')" = 0 ]
}

@test "text output groups findings by user and check" {
  seed_findings
  run --separate-stderr "$SCRIPT" example-user
  [ "$status" -eq 1 ]
  [[ "$output" == *"== example-user"* ]]
  [[ "$output" == *"Repository access"* ]]
  [[ "$output" == *"example-org/repo-one: write (direct)"* ]]
  [[ "$output" == *"gh api -X DELETE repos/example-org/repo-one/collaborators/example-user"* ]]
  [[ "$output" != *"gh api -X DELETE orgs/"* ]]
  [[ "$output" != *"# org owner"* ]]
  [[ "$output" != *"repo admin:"* ]]
  [[ "$output" == *"CODEOWNERS (code search)"* ]]
  [[ "$output" == *"example-org/repo-one: .github/codeowners"* ]]
  [[ "$output" == *"example-org/repo-three: .github/CODEOWNERS"* ]]
  [[ "$output" != *"@example-admin"* ]]
  [[ "$output" != *"# edit"* ]]
  [[ "$output" == *"Environment required reviewers"* ]]
  [[ "$output" == *"github-drop-env-reviewer.sh"* ]]
  [[ "$output" != *"Open issues and pull requests assigned"* ]]
  echo "$output" | grep -qx 'gh api -X DELETE repos/example-org/repo-one/collaborators/example-user'
  [ -z "$(echo "$output" | grep -E '^ +gh api' || true)" ]
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

@test "--org accepts a comma list and equals form" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json --org=bcgov,other-org --repo example-org/repo-one example-user
  [ "$(echo "$output" | jq -c '.orgs')" = '["bcgov","other-org"]' ]
  grep -q 'orgs/bcgov/members' "$STUB_LOG"
  grep -q 'orgs/other-org/members' "$STUB_LOG"
}

@test "default organizations are bcgov and bcgov-c" {
  unset OFFBOARD_ORGS
  seed_findings
  run --separate-stderr "$SCRIPT" --json --repo example-org/repo-one example-user
  [ "$(echo "$output" | jq -c '.orgs')" = '["bcgov","bcgov-c"]' ]
}

@test "--org-owner prints org and team DELETE commands" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json --org-owner example-user
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "org-membership") | .cmd | test("# org owner")'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "team") | .cmd | test("teams/.*/memberships/")'
  run --separate-stderr "$SCRIPT" --org-owner example-user
  [ "$status" -eq 1 ]
  echo "$output" | grep -qx 'gh api -X DELETE orgs/example-org/members/example-user'
  echo "$output" | grep -qx '# org owner'
}

@test "only read-only GitHub calls are made" {
  seed_findings
  run "$SCRIPT" --json example-user
  [ -z "$(grep -E -- '-X (POST|PUT|PATCH|DELETE)|--method|--input|-F ' "$STUB_LOG")" ]
  [ -z "$(grep -E '^gh api' "$STUB_LOG" | grep -E -- ' -f ' | grep -vE 'graphql|search/|-X GET')" ]
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
  run grep -c 'search/code' "$STUB_LOG"
  [ "$output" = 2 ]
  [ -z "$(grep 'search/code' "$STUB_LOG" | grep '(' || true)" ]
  run grep -c 'userLogins:\["missing-user"\]' "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "matching is case insensitive" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json Example-User
  [ "$status" -eq 1 ]
  counts="$(echo "$output" | jq -c '.users[0].findings | group_by(.check) | map({(.[0].check): length}) | add')"
  [ "$counts" = '{"codeowners":1,"codeowners-search":1,"environment-reviewer":1,"org-membership":1,"repo-collaborator":1,"team":1}' ]
  grep -q 'example-user filename:CODEOWNERS' "$STUB_LOG"
}

@test "an API failure exits 3" {
  seed_findings
  GH_FAIL_MATCH='CODEOWNERS' run "$SCRIPT" example-user
  [ "$status" -eq 3 ]
  [[ "$output" == *"HTTP 500"* ]]
}

@test "a search failure still prints the checks already done" {
  seed_findings
  GH_FAIL_MATCH='search/code' run "$SCRIPT" example-user
  [ "$status" -eq 3 ]
  [[ "$output" == *"example-org/repo-one: write (direct)"* ]]
  [[ "$output" == *"search failed (HTTP 500)"* ]]
}

@test "github-drop-env-reviewer puts remaining reviewers" {
  cat > "$FIXTURES/env-one" <<'JSON'
{"protection_rules":[
  {"type":"wait_timer","wait_timer":5},
  {"type":"required_reviewers","prevent_self_review":true,"reviewers":[
    {"type":"User","reviewer":{"id":1,"login":"example-user"}},
    {"type":"User","reviewer":{"id":2,"login":"keep-me"}}
  ]}
]}
JSON
  run "${BATS_TEST_DIRNAME}/../github-drop-env-reviewer.sh" example-org/repo-one prod example-user
  [ "$status" -eq 0 ]
  grep -q -- '-X PUT repos/example-org/repo-one/environments/prod' "$STUB_LOG"
}
