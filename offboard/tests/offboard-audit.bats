#!/usr/bin/env bats
# Tests for offboard-audit.sh with stubbed gh and oc on PATH. No network access.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../offboard-audit.sh"
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
  printf 'prod\tUser\texample-user\ntest\tTeam\tteam-a\nuat\tTeam\tteam-b\n' > "$FIXTURES/env-repo-one"
  printf '# @example-user in a comment\n*  @example-admin @example-user\n/docs/ @example-user-two\n' > "$FIXTURES/codeowners-repo-one"
  cat > "$FIXTURES/search-code" <<'JSON'
{"items":[
 {"repository":{"full_name":"example-org/repo-three"},"path":".github/CODEOWNERS","text_matches":[{"fragment":"* @example-user"}]},
 {"repository":{"full_name":"example-org/repo-four"},"path":"CODEOWNERS","text_matches":[{"fragment":"* @example-user-two"}]}
]}
JSON
  printf 'https://github.com/example-org/repo-one/issues/1\tissue\tAn issue\nhttps://github.com/example-org/repo-one/pull/2\tpull request\tA change\n' > "$FIXTURES/search-assigned"
  printf 'https://github.com/example-org/repo-one/pull/3\tNeeds review\n' > "$FIXTURES/search-review"
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

@test "--idir with more than one user is a usage error" {
  run "$SCRIPT" --idir someone example-user example-user-two
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

@test "a login that is not found prints the rename hint and still runs the text checks" {
  printf 'example-org/repo-one\n' > "$FIXTURES/user-repos"
  printf 'example-admin\tadmin\n' > "$FIXTURES/collab-all-repo-one"
  printf '*  @missing-user\n' > "$FIXTURES/codeowners-repo-one"
  printf 'example-org\n' > "$FIXTURES/member-orgs"
  run --separate-stderr "$SCRIPT" --json missing-user
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"user not found; they may have been renamed. Re-run with the new login and --alias missing-user"* ]]
  [ "$(echo "$output" | jq '.users[0].id')" = null ]
  [ "$(echo "$output" | jq -c '[.users[0].findings[].check]')" = '["codeowners"]' ]
  echo "$output" | jq -e '.notes[] | select(test("missing-user: user not found"))'
  run grep -cE 'members/missing-user|userLogins|search/issues' "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "--alias with more than one user is a usage error" {
  run "$SCRIPT" --alias old-user example-user example-user-two
  [ "$status" -eq 2 ]
}

@test "the numeric user ID is printed" {
  printf 'example-org/repo-one\n' > "$FIXTURES/user-repos"
  STUB_USER_ID=987654 run --separate-stderr "$SCRIPT" example-user
  [[ "$output" == *"== example-user (id 987654)"* ]]
  STUB_USER_ID=987654 run --separate-stderr "$SCRIPT" --json example-user
  [ "$(echo "$output" | jq '.users[0].id')" = 987654 ]
}

@test "--alias matches CODEOWNERS and code search, and reports which name matched" {
  printf 'example-org/repo-one\n' > "$FIXTURES/user-repos"
  printf '*  @Old-User\n/docs/ @example-user\n' > "$FIXTURES/codeowners-repo-one"
  cat > "$FIXTURES/search-code" <<'JSON'
{"items":[{"repository":{"full_name":"example-org/repo-three"},"path":"CODEOWNERS","text_matches":[{"fragment":"* @old-user"}]}]}
JSON
  run --separate-stderr "$SCRIPT" --json --alias old-user example-user
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -c '[.users[0].findings[] | select(.check == "codeowners") | .matched] | sort')" = '["example-user","old-user"]' ]
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "codeowners-search" and .target == "example-org/repo-three" and .matched == "old-user")'
  [ "$(echo "$output" | jq -c '.users[0].aliases')" = '["old-user"]' ]
  grep -q 'q=old-user filename:CODEOWNERS' "$STUB_LOG"
  run --separate-stderr "$SCRIPT" --alias old-user example-user
  [[ "$output" == *"[matched old-user]"* ]]
}

@test "nothing found exits 0 and notes the OpenShift skip" {
  printf 'example-org/repo-one\n' > "$FIXTURES/user-repos"
  printf 'example-admin\tadmin\n' > "$FIXTURES/collab-all-repo-one"
  run "$SCRIPT" example-user
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing found"* ]]
  [[ "$output" == *"OpenShift check skipped"* ]]
}

@test "findings in every GitHub check exit 1 (json)" {
  seed_findings
  run --separate-stderr "$SCRIPT" --json example-user
  [ "$status" -eq 1 ]
  counts="$(echo "$output" | jq -c '.users[0].findings | group_by(.check) | map({(.[0].check): length}) | add')"
  [ "$counts" = '{"assigned":2,"codeowners":1,"codeowners-search":1,"environment-reviewer":2,"org-membership":1,"repo-collaborator":1,"review-requested":1,"team":1}' ]
  [ "$(echo "$output" | jq -r '.repos_checked')" = 1 ]
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "repo-collaborator" and .detail == "write (direct)")'
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "environment-reviewer" and (.detail | test("through team team-a")))'
  [ "$(echo "$output" | jq '[.users[0].findings[] | select(.detail | test("team-b|repo-four|example-user-two"))] | length')" = 0 ]
}

@test "text output groups findings by user and check" {
  seed_findings
  run --separate-stderr "$SCRIPT" example-user
  [ "$status" -eq 1 ]
  [[ "$output" == *"== example-user"* ]]
  [[ "$output" == *"Repository access"* ]]
  [[ "$output" == *"example-org/repo-one: write (direct)"* ]]
  [[ "$output" == *"Pull requests waiting on their review"* ]]
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
  grep -q 'org:other-org' "$STUB_LOG"
  run grep -c 'org:example-org' "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "OpenShift RoleBindings are matched when oc is logged in" {
  printf 'ns-a\nns-b\nns-c\n' > "$FIXTURES/oc-projects"
  cat > "$FIXTURES/rb-ns-a" <<'JSON'
{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"example-user@github"}]},
          {"metadata":{"name":"rb2"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"someone-else"}]}]}
JSON
  cat > "$FIXTURES/rb-ns-b" <<'JSON'
{"items":[{"metadata":{"name":"rb3"},"roleRef":{"name":"view"},"subjects":[{"kind":"User","name":"EXAMPLEIDIR@idir"},{"kind":"Group","name":"example-user"}]}]}
JSON
  OC_WHOAMI_RC=0 run --separate-stderr "$SCRIPT" --json --idir exampleidir example-user
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq '[.users[0].findings[] | select(.check == "openshift-rolebinding")] | length')" = 2 ]
  echo "$output" | jq -e '.notes[] | select(test("not readable in 1 namespace"))'
}

@test "OpenShift subjects match aliases, emails case-insensitively, and report the form" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  cat > "$FIXTURES/rb-ns-a" <<'JSON'
{"items":[{"metadata":{"name":"rb1"},"roleRef":{"name":"admin"},"subjects":[{"kind":"User","name":"Old-User@GitHub"}]},
          {"metadata":{"name":"rb2"},"roleRef":{"name":"edit"},"subjects":[{"kind":"User","name":"First.Last@Gov.BC.CA"}]},
          {"metadata":{"name":"rb3"},"roleRef":{"name":"view"},"subjects":[{"kind":"User","name":"other@gov.bc.ca"}]}]}
JSON
  OC_WHOAMI_RC=0 run --separate-stderr "$SCRIPT" --json --alias old-user --email first.last@gov.bc.ca example-user
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -c '[.users[0].findings[] | select(.check == "openshift-rolebinding") | {target, matched}] | sort_by(.matched)')" = '[{"target":"ns-a","matched":"first.last@gov.bc.ca"},{"target":"ns-a","matched":"old-user@github"}]' ]
  echo "$output" | jq -e '.users[0].findings[] | select(.detail | test("subject Old-User@GitHub"))'
}

@test "group users lists are checked when groups can be listed" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[]}' > "$FIXTURES/rb-ns-a"
  cat > "$FIXTURES/oc-groups" <<'JSON'
{"items":[{"metadata":{"name":"team-admins"},"users":["someone@github","EXAMPLE-USER@github"]},
          {"metadata":{"name":"other"},"users":["someone@github"]}]}
JSON
  OC_WHOAMI_RC=0 run --separate-stderr "$SCRIPT" --json example-user
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -c '[.users[0].findings[] | select(.check == "openshift-group") | {target, matched}]')" = '[{"target":"team-admins","matched":"example-user@github"}]' ]
  echo "$output" | jq -e '.notes[] | select(. == "OpenShift: can'"'"'t list users in this context; skipped")'
}

@test "groups that cannot be listed give one note, not an error" {
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[]}' > "$FIXTURES/rb-ns-a"
  OC_WHOAMI_RC=0 run --separate-stderr "$SCRIPT" --json example-user
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.notes[] | select(. == "OpenShift: can'"'"'t list groups in this context; skipped")] | length')" = 1 ]
  run grep -c '^oc get groups' "$STUB_LOG"
  [ "$output" = 0 ]
}

@test "only read-only calls are made" {
  seed_findings
  printf 'ns-a\n' > "$FIXTURES/oc-projects"
  echo '{"items":[]}' > "$FIXTURES/rb-ns-a"
  echo '{"items":[]}' > "$FIXTURES/oc-groups"
  echo '{"items":[{"metadata":{"name":"example-user@github"},"identities":["github:example-user"]}]}' > "$FIXTURES/oc-users"
  OC_WHOAMI_RC=0 run --separate-stderr "$SCRIPT" --json example-user
  grep -q '^oc get rolebindings' "$STUB_LOG"
  grep -q '^oc get groups -o json$' "$STUB_LOG"
  echo "$output" | jq -e '.users[0].findings[] | select(.check == "openshift-user" and .target == "example-user@github")' 
  [ -z "$(grep -E -- '-X (POST|PUT|PATCH|DELETE)|--method|--input|-F ' "$STUB_LOG")" ]
  [ -z "$(grep -E '^gh api' "$STUB_LOG" | grep -E -- ' -f ' | grep -vE 'graphql|search/|-X GET')" ]
  [ -z "$(grep -E '^oc ' "$STUB_LOG" | grep -vE '^oc (whoami|projects -q|get rolebindings -n [a-z0-9-]+ -o json|auth can-i list (groups|users)|get (groups|users) -o json)$')" ]
}

@test "an API failure exits 3" {
  seed_findings
  GH_FAIL_MATCH='environments' run "$SCRIPT" example-user
  [ "$status" -eq 3 ]
  [[ "$output" == *"HTTP 500"* ]]
}
