#!/usr/bin/env bats
# Tests for offboard-openshift.sh with stubbed oc on PATH. No network access.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../offboard-openshift.sh"
  export FIXTURES="${BATS_TEST_TMPDIR}/fx"
  export STUB_LOG="${BATS_TEST_TMPDIR}/calls.log"
  mkdir -p "$FIXTURES"
  : > "$STUB_LOG"
  PATH="${BATS_TEST_DIRNAME}/stubs:${PATH}"
  export PATH
  export OC_WHOAMI_RC=0
}

@test "no names is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"pass --name"* ]]
}

@test "oc not logged in is an error" {
  OC_WHOAMI_RC=1 run "$SCRIPT" --name example-user
  [ "$status" -eq 2 ]
  [[ "$output" == *"not logged in"* ]]
}

@test "a name matches every subject that contains it" {
  printf 'ns-a\nns-b\nns-c\n' > "$FIXTURES/oc-projects"
  cat > "$FIXTURES/rb-ns-a" <<'JSON'
{"items":[
  {"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]},
  {"metadata":{"name":"rb2"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"First.Last@gov.bc.ca"}]},
  {"metadata":{"name":"rb4"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"example-user@gov.bc.ca"}]},
  {"metadata":{"name":"rb6"},"roleRef":{"name":"view"},"subjects":[{"kind":"User","name":"someone-else"}]}
]}
JSON
  cat > "$FIXTURES/rb-ns-b" <<'JSON'
{"items":[{"metadata":{"name":"rb3"},"roleRef":{"name":"view"},"subjects":[{"kind":"Group","name":"example-user"}]}]}
JSON
  run --separate-stderr "$SCRIPT" --json --name example-user --name first.last
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq '[.sections[] | select(.name == "example-user") | .findings[]] | length')" = 2 ]
  [ "$(echo "$output" | jq '[.sections[] | select(.name == "first.last") | .findings[]] | length')" = 1 ]
  [ "$(echo "$output" | jq '[.sections[].findings[] | select(.detail | test("someone-else"))] | length')" = 0 ]
  echo "$output" | jq -e '.notes[] | select(test("not readable in 1 namespace"))'
  echo "$output" | jq -e '.sections[] | select(.name == "example-user") | .findings[] | select(.cmd | test("oc adm policy remove-role-from-user"))'
  echo "$output" | jq -e '.sections[] | select(.name == "example-user") | .findings[] | select(.detail == "rb1 -> admin")'
  [ "$(echo "$output" | jq '[.sections[].findings[] | select(.detail | test("subject"))] | length')" = 0 ]
  run grep -c 'oc get rolebindings' "$STUB_LOG"
  [ "$output" = 3 ]
}

@test "a different spelling does not match" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"view"},"subjects":[{"kind":"User","name":"greg.pascucci@gov.bc.ca"}]}]}' > "$FIXTURES/rb-ns-a"
  run --separate-stderr "$SCRIPT" --json --name greg.pascucchi
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.sections[].findings[]] | length')" = 0 ]
}

@test "subject matching is case insensitive" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@GITHUB"}]}]}' > "$FIXTURES/rb-ns-a"
  run --separate-stderr "$SCRIPT" --json --name Example-User
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq '[.sections[] | select(.name == "Example-User") | .findings[]] | length')" = 1 ]
}

@test "text output prints oc commands at column 0" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/rb-ns-a"
  run --separate-stderr "$SCRIPT" --name example-user
  [ "$status" -eq 1 ]
  [[ "$output" == *"rb1 -> admin"* ]]
  [[ "$output" != *"(subject "* ]]
  echo "$output" | grep -qx 'oc adm policy remove-role-from-user admin example-user@github -n ns-a'
  [ -z "$(echo "$output" | grep -E '^ +oc adm' || true)" ]
}

@test "only read-only calls are made" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[]}' > "$FIXTURES/rb-ns-a"
  run "$SCRIPT" --name example-user
  [ -z "$(grep -E -- '-X (POST|PUT|PATCH|DELETE)|--method|--input' "$STUB_LOG")" ]
  [ -z "$(grep -E '^oc ' "$STUB_LOG" | grep -vE '^oc (whoami|projects -q|get rolebindings -n [a-z0-9-]+ -o json)$')" ]
  [ -z "$(grep '^gh ' "$STUB_LOG" || true)" ]
}
