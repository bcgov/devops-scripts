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
  printf '* @example-user\n' > "$FIXTURES/codeowners-repo-one"
}

@test "no arguments off a terminal is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"at least one person"* ]]
}

@test "one person groups GitHub and OpenShift" {
  seed_github
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"},{"kind":"User","name":"first.last@gov.bc.ca"}]}]}' > "$FIXTURES/rb-ns-a"
  run "$SCRIPT" 'example-user=first.last'
  [ "$status" -eq 1 ]
  [[ "$output" == *"== example-user=first.last"* ]]
  [[ "$output" == *"GitHub: example-user"* ]]
  [[ "$output" == *"example-org/repo-one: write (direct)"* ]]
  [[ "$output" == *"gh api -X DELETE repos/example-org/repo-one/collaborators/example-user"* ]]
  [[ "$output" == *"OpenShift: first.last"* ]]
  [[ "$output" == *"first.last@gov.bc.ca"* ]]
  [[ "$output" == *"oc adm policy remove-role-from-user"* ]]
  [[ "$output" != *"== first.last"* ]]
  echo "$output" | grep -qx 'gh api -X DELETE repos/example-org/repo-one/collaborators/example-user'
  echo "$output" | grep -qx 'oc adm policy remove-role-from-user admin example-user@github -n ns-a'
  echo "$output" | grep -qx 'oc adm policy remove-role-from-user admin first.last@gov.bc.ca -n ns-a'
  [ -z "$(echo "$output" | grep -E '^ +(gh api|oc adm)' || true)" ]
  [[ "$output" != *"(subject "* ]]
  [[ "$output" != *"gh api -X DELETE orgs/"* ]]
}

@test "--org-owner includes org DELETE commands" {
  seed_github
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[]}' > "$FIXTURES/rb-ns-a"
  run "$SCRIPT" --org-owner example-user
  [ "$status" -eq 1 ]
  echo "$output" | grep -qx 'gh api -X DELETE orgs/example-org/members/example-user'
}

@test "--org is passed through to the GitHub audit" {
  seed_github
  OC_WHOAMI_RC=1 run "$SCRIPT" --org=example-org,other-org example-user
  [ "$status" -eq 1 ]
  grep -q 'orgs/other-org/members' "$STUB_LOG"
}

@test "a missing oc login still prints GitHub" {
  seed_github
  OC_WHOAMI_RC=1 run "$SCRIPT" 'example-user=first.last'
  [ "$status" -eq 1 ]
  [[ "$output" == *"GitHub: example-user"* ]]
  [[ "$output" == *"example-org/repo-one: write (direct)"* ]]
  [[ "$output" == *"OpenShift skipped: oc is not logged in"* ]]
  [[ "$output" == *"--name example-user"* ]]
  [[ "$output" == *"--name first.last"* ]]
  [ -z "$(grep 'oc get rolebindings' "$STUB_LOG" || true)" ]
}

@test "a GitHub API failure still runs OpenShift" {
  seed_github
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/rb-ns-a"
  GH_FAIL_MATCH=CODEOWNERS run "$SCRIPT" example-user
  [ "$status" -eq 3 ]
  [[ "$output" == *"GitHub audit failed"* ]]
  [[ "$output" == *"example-user@github"* ]]
  grep -q 'oc get rolebindings' "$STUB_LOG"
}

@test "offboard.sh multi-cluster groups OpenShift across clusters" {
  seed_github
  cat > "$FIXTURES/oc-config.json" <<'JSON'
{
  "current-context": "silver-ctx",
  "contexts": [
    {"name": "silver-ctx", "context": {"cluster": "silver-cluster"}},
    {"name": "gold-ctx", "context": {"cluster": "gold-cluster"}}
  ],
  "clusters": [
    {"name": "silver-cluster", "cluster": {"server": "https://api.silver.devops.gov.bc.ca:6443"}},
    {"name": "gold-cluster", "cluster": {"server": "https://api.gold.devops.gov.bc.ca:6443"}}
  ]
}
JSON
  printf 'silver-ns\n' > "$FIXTURES/oc-projects-silver-ctx"
  printf 'gold-ns\n' > "$FIXTURES/oc-projects-gold-ctx"
  echo '{"items":[{"metadata":{"name":"rb-silver"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"first.last@gov.bc.ca"}]}]}' > "$FIXTURES/silver-ctx-rb-silver-ns"
  echo '{"items":[{"metadata":{"name":"rb-gold"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"first.last@gov.bc.ca"}]}]}' > "$FIXTURES/gold-ctx-rb-gold-ns"

  run "$SCRIPT" 'example-user=first.last'
  [ "$status" -eq 1 ]
  [[ "$output" == *"== example-user=first.last"* ]]
  [[ "$output" == *"GitHub: example-user"* ]]
  [[ "$output" == *"OpenShift: first.last"* ]]
  [[ "$output" == *"   - [silver] silver-ns: rb-silver -> admin"* ]]
  [[ "$output" == *"   - [gold] gold-ns: rb-gold -> edit"* ]]
  echo "$output" | grep -qx 'oc --context silver-ctx adm policy remove-role-from-user admin first.last@gov.bc.ca -n silver-ns'
  echo "$output" | grep -qx 'oc --context gold-ctx adm policy remove-role-from-user edit first.last@gov.bc.ca -n gold-ns'
}

@test "offboard.sh -c passes through single cluster mode" {
  seed_github
  cat > "$FIXTURES/oc-config.json" <<'JSON'
{
  "current-context": "silver-ctx",
  "contexts": [
    {"name": "silver-ctx", "context": {"cluster": "silver-cluster"}},
    {"name": "gold-ctx", "context": {"cluster": "gold-cluster"}}
  ],
  "clusters": [
    {"name": "silver-cluster", "cluster": {"server": "https://api.silver.devops.gov.bc.ca:6443"}},
    {"name": "gold-cluster", "cluster": {"server": "https://api.gold.devops.gov.bc.ca:6443"}}
  ]
}
JSON
  printf 'silver-ns\n' > "$FIXTURES/oc-projects"
  echo '{"items":[{"metadata":{"name":"rb-silver"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"first.last@gov.bc.ca"}]}]}' > "$FIXTURES/rb-silver-ns"

  run "$SCRIPT" -c 'example-user=first.last'
  [ "$status" -eq 1 ]
  [[ "$output" == *"OpenShift: first.last"* ]]
  [[ "$output" == *"   - silver-ns: rb-silver -> admin"* ]]
  [[ "$output" != *"   - [silver]"* ]]
  echo "$output" | grep -qx 'oc adm policy remove-role-from-user admin first.last@gov.bc.ca -n silver-ns'
}
