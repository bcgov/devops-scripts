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

@test "no lists is a usage error" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--github or --gov"* ]]
}

@test "oc not logged in is an error" {
  OC_WHOAMI_RC=1 run "$SCRIPT" --github example-user
  [ "$status" -eq 2 ]
  [[ "$output" == *"not logged in"* ]]
}

@test "github and gov lists stay on their own domains" {
  printf 'ns-a\nns-b\nns-c\n' > "$FIXTURES/oc-projects"
  cat > "$FIXTURES/rb-ns-a" <<'JSON'
{"items":[
  {"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]},
  {"metadata":{"name":"rb2"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"First.Last@gov.bc.ca"}]},
  {"metadata":{"name":"rb4"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"example-user@gov.bc.ca"}]},
  {"metadata":{"name":"rb5"},"roleRef":{"name":"view"},"subjects":[{"kind":"User","name":"first.last@github"}]},
  {"metadata":{"name":"rb6"},"roleRef":{"name":"view"},"subjects":[{"kind":"User","name":"someone-else"}]}
]}
JSON
  cat > "$FIXTURES/rb-ns-b" <<'JSON'
{"items":[{"metadata":{"name":"rb3"},"roleRef":{"name":"view"},"subjects":[{"kind":"Group","name":"example-user"}]}]}
JSON
  run --separate-stderr "$SCRIPT" --json --github example-user --gov first.last
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq '[.sections[] | select(.name == "example-user") | .findings[]] | length')" = 1 ]
  [ "$(echo "$output" | jq '[.sections[] | select(.name == "first.last") | .findings[]] | length')" = 1 ]
  echo "$output" | jq -e '.sections[] | select(.name == "example-user") | .findings[] | select(.detail | test("subject example-user@github"))'
  [ "$(echo "$output" | jq '[.sections[].findings[] | select(.detail | test("example-user@gov.bc.ca|first.last@github|someone-else"))] | length')" = 0 ]
  echo "$output" | jq -e '.notes[] | select(test("not readable in 1 namespace"))'
  run grep -c 'oc get rolebindings' "$STUB_LOG"
  [ "$output" = 3 ]
}

@test "subject matching is case insensitive" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  cat > "$FIXTURES/rb-ns-a" <<'JSON'
{"items":[
  {"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@GITHUB"}]},
  {"metadata":{"name":"rb2"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"first.last@gov.bc.ca"}]}
]}
JSON
  run --separate-stderr "$SCRIPT" --json --github Example-User --gov First.Last
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq '[.sections[] | select(.name == "Example-User") | .findings[]] | length')" = 1 ]
  [ "$(echo "$output" | jq '[.sections[] | select(.name == "First.Last") | .findings[]] | length')" = 1 ]
}

@test "only read-only calls are made" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[]}' > "$FIXTURES/rb-ns-a"
  run "$SCRIPT" --github example-user
  [ -z "$(grep -E -- '-X (POST|PUT|PATCH|DELETE)|--method|--input' "$STUB_LOG")" ]
  [ -z "$(grep -E '^oc ' "$STUB_LOG" | grep -vE '^oc (whoami|projects -q|get rolebindings -n [a-z0-9-]+ -o json)$')" ]
  [ -z "$(grep '^gh ' "$STUB_LOG" || true)" ]
}
