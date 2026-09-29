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
  printf 'example-user\n' > "${BATS_TEST_TMPDIR}/github.txt"
  printf 'first.last\n' > "${BATS_TEST_TMPDIR}/gov.txt"
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
  [[ "$output" == *"--github-file"* ]]
}

@test "both reports run and a missing oc login still prints GitHub" {
  seed_github
  OC_WHOAMI_RC=1 run "$SCRIPT" --github-file "${BATS_TEST_TMPDIR}/github.txt" --gov-file "${BATS_TEST_TMPDIR}/gov.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"=== GitHub ==="* ]]
  [[ "$output" == *"=== OpenShift ==="* ]]
  [[ "$output" == *"OpenShift skipped: oc is not logged in"* ]]
  [[ "$output" == *"--github-file ${BATS_TEST_TMPDIR}/github.txt"* ]]
  [[ "$output" == *"example-org/repo-one: write (direct)"* ]]
  [ -z "$(grep 'oc get rolebindings' "$STUB_LOG" || true)" ]
}

@test "a GitHub API failure still runs OpenShift" {
  seed_github
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/rb-ns-a"
  GH_FAIL_MATCH=environments run "$SCRIPT" --github-file "${BATS_TEST_TMPDIR}/github.txt"
  [ "$status" -eq 3 ]
  [[ "$output" == *"=== OpenShift ==="* ]]
  [[ "$output" == *"example-user@github"* ]]
  grep -q 'oc get rolebindings' "$STUB_LOG"
}
