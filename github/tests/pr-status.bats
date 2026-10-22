#!/usr/bin/env bats
# Argument checks for pr-status.sh. No network access: each case exits before calling gh.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../pr-status.sh"
}

@test "help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Check one PR's readiness"* ]]
}

@test "unknown argument is a usage error" {
  run "$SCRIPT" --rerun
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument: --rerun"* ]]
}

@test "two PRs is a usage error" {
  run "$SCRIPT" 1 2
  [ "$status" -eq 2 ]
  [[ "$output" == *"only one PR"* ]]
}

@test "a PR that is not a number or URL is a usage error" {
  run "$SCRIPT" main
  [ "$status" -eq 2 ]
}

@test "report filters with a PR is a usage error" {
  run "$SCRIPT" --orgs my-org 12
  [ "$status" -eq 2 ]
  [[ "$output" == *"report mode"* ]]
}

@test "-R without a PR is a usage error" {
  run "$SCRIPT" -R my-org/app
  [ "$status" -eq 2 ]
}

@test "--orgs and --repos together is a usage error" {
  run "$SCRIPT" --orgs my-org --repos my-org/app
  [ "$status" -eq 2 ]
}

@test "--quiet-minutes must be a number" {
  run "$SCRIPT" --quiet-minutes ten 12
  [ "$status" -eq 2 ]
}

@test "excluding every repo is a usage error" {
  run "$SCRIPT" --repos my-org/app --exclude 'my-org/*'
  [ "$status" -eq 2 ]
  [[ "$output" == *"no repos to scan"* ]]
}
