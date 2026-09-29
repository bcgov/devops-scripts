#!/usr/bin/env bats
# Tests for offboard.sh. Stubbed gh and oc. No network access.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../offboard.sh"
  export FIXTURES="${BATS_TEST_TMPDIR}/fx"
  export STUB_LOG="${BATS_TEST_TMPDIR}/calls.log"
  mkdir -p "$FIXTURES"
  : > "$STUB_LOG"
  PATH="${BATS_TEST_DIRNAME}/stubs:${PATH}"
  export PATH
  export OFFBOARD_ORGS="example-org"
  export OC_WHOAMI_RC=0
  unset GH_AUTH_RC GH_FAIL_MATCH
}

seed_github() {
  printf 'example-org\n' > "$FIXTURES/member-orgs"
  printf 'team-a\n' > "$FIXTURES/teams-example-org"
  printf 'example-org/repo-one\n' > "$FIXTURES/user-repos"
  printf 'example-user\twrite\n' > "$FIXTURES/collab-all-repo-one"
  printf 'example-user\n' > "$FIXTURES/collab-direct-repo-one"
  printf 'prod\tUser\texample-user\n' > "$FIXTURES/env-repo-one"
  printf '* @example-user\n' > "$FIXTURES/codeowners-repo-one"
  echo '{"items":[]}' > "$FIXTURES/search-code"
  printf 'https://github.com/example-org/repo-one/issues/1\tissue\tAn issue\texample-user\n' > "$FIXTURES/search-assigned"
  printf 'https://github.com/example-org/repo-one/pull/3\tNeeds review\n' > "$FIXTURES/search-review"
}

@test "no arguments off a terminal is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--github"* ]]
}

@test "both reports run and a missing oc login still prints GitHub" {
  seed_github
  OC_WHOAMI_RC=1 run "$SCRIPT" --github example-user --gov first.last
  [ "$status" -eq 1 ]
  [[ "$output" == *"=== GitHub ==="* ]]
  [[ "$output" == *"=== OpenShift ==="* ]]
  [[ "$output" == *"OpenShift skipped: oc is not logged in"* ]]
  [[ "$output" == *"--github example-user"* ]]
  [[ "$output" == *"--gov first.last"* ]]
  [[ "$output" == *"example-org/repo-one: write (direct)"* ]]
  [ -z "$(grep 'oc get rolebindings' "$STUB_LOG" || true)" ]
}

@test "a GitHub API failure still runs OpenShift" {
  seed_github
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/rb-ns-a"
  GH_FAIL_MATCH=environments run "$SCRIPT" --github example-user
  [ "$status" -eq 3 ]
  [[ "$output" == *"=== OpenShift ==="* ]]
  [[ "$output" == *"example-user@github"* ]]
  grep -q 'oc get rolebindings' "$STUB_LOG"
}
