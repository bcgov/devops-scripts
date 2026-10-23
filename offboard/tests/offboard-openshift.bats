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
  [ -z "$(grep -E '^oc ' "$STUB_LOG" | grep -vE '^oc (--context [a-z0-9-]+ )?(whoami|projects -q|config view -o json|get rolebindings -n [a-z0-9-]+ -o json)$')" ]
  [ -z "$(grep '^gh ' "$STUB_LOG" || true)" ]
}

@test "multi-cluster queries distinct authenticated clusters and outputs context in commands" {
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
  echo '{"items":[{"metadata":{"name":"rb-silver"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/silver-ctx-rb-silver-ns"
  echo '{"items":[{"metadata":{"name":"rb-gold"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/gold-ctx-rb-gold-ns"

  run --separate-stderr "$SCRIPT" --json --name example-user
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq '.clusters_checked')" = 2 ]
  [ "$(echo "$output" | jq '[.sections[] | select(.name == "example-user") | .findings[]] | length')" = 2 ]
  echo "$output" | jq -e '.sections[].findings[] | select(.cluster == "silver" and .target == "silver-ns")'
  echo "$output" | jq -e '.sections[].findings[] | select(.cluster == "gold" and .target == "gold-ns")'
  echo "$output" | jq -e '.sections[].findings[] | select(.cmd == "oc --context silver-ctx adm policy remove-role-from-user admin example-user@github -n silver-ns")'
  echo "$output" | jq -e '.sections[].findings[] | select(.cmd == "oc --context gold-ctx adm policy remove-role-from-user edit example-user@github -n gold-ns")'
}

@test "multi-cluster text output prepends cluster tags and prints commands" {
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
  echo '{"items":[{"metadata":{"name":"rb-silver"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/silver-ctx-rb-silver-ns"
  echo '{"items":[{"metadata":{"name":"rb-gold"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/gold-ctx-rb-gold-ns"

  run --separate-stderr "$SCRIPT" --name example-user
  [ "$status" -eq 1 ]
  [[ "$output" == *"Clusters checked: 2"* ]]
  [[ "$output" == *"   - [silver] silver-ns: rb-silver -> admin"* ]]
  [[ "$output" == *"   - [gold] gold-ns: rb-gold -> edit"* ]]
  echo "$output" | grep -qx 'oc --context silver-ctx adm policy remove-role-from-user admin example-user@github -n silver-ns'
  echo "$output" | grep -qx 'oc --context gold-ctx adm policy remove-role-from-user edit example-user@github -n gold-ns'
}

@test "-c and --current-cluster restrict query to the active context" {
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
  echo '{"items":[{"metadata":{"name":"rb-silver"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/rb-silver-ns"

  run --separate-stderr "$SCRIPT" -c --name example-user
  [ "$status" -eq 1 ]
  [[ "$output" != *"Clusters checked:"* ]]
  [[ "$output" == *"   - silver-ns: rb-silver -> admin"* ]]
  [[ "$output" != *"   - [silver]"* ]]
  echo "$output" | grep -qx 'oc adm policy remove-role-from-user admin example-user@github -n silver-ns'
}

@test "--context targets a specific context directly" {
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
  printf 'gold-ns\n' > "$FIXTURES/oc-projects-gold-ctx"
  echo '{"items":[{"metadata":{"name":"rb-gold"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/gold-ctx-rb-gold-ns"

  run --separate-stderr "$SCRIPT" --context gold-ctx --name example-user
  [ "$status" -eq 1 ]
  [[ "$output" == *"   - gold-ns: rb-gold -> edit"* ]]
  echo "$output" | grep -qx 'oc --context gold-ctx adm policy remove-role-from-user edit example-user@github -n gold-ns'
}

@test "unreachable cluster is skipped with warning in multi-cluster mode" {
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
  echo 1 > "$FIXTURES/whoami-gold-ctx-rc"
  printf 'silver-ns\n' > "$FIXTURES/oc-projects-silver-ctx"
  echo '{"items":[{"metadata":{"name":"rb-silver"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]}]}' > "$FIXTURES/silver-ctx-rb-silver-ns"

  run --separate-stderr "$SCRIPT" --name example-user
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Warning: Skipping cluster 'gold'"* ]]
  [[ "$output" == *"   - silver-ns: rb-silver -> admin"* ]]
  echo "$output" | grep -qx 'oc --context silver-ctx adm policy remove-role-from-user admin example-user@github -n silver-ns'
}
