#!/usr/bin/env bats
# Argument checks for rerun-blocked.sh. No network access: each case exits before calling gh.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../rerun-blocked.sh"
}

@test "help exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--pattern REGEX"* ]]
}

@test "unknown argument is a usage error" {
  run "$SCRIPT" --rerun
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument: --rerun"* ]]
}

@test "--orgs and --repos together is a usage error" {
  run "$SCRIPT" --orgs my-org --repos my-org/app
  [ "$status" -eq 2 ]
}

@test "--days must be a positive number" {
  run "$SCRIPT" --days 0
  [ "$status" -eq 2 ]
}

@test "--repos entries must be OWNER/NAME" {
  run "$SCRIPT" --repos app
  [ "$status" -eq 2 ]
  [[ "$output" == *"OWNER/NAME"* ]]
}

@test "an invalid --pattern is a usage error" {
  run "$SCRIPT" --pattern '('
  [ "$status" -eq 2 ]
}

@test "excluding every repo is a usage error" {
  run "$SCRIPT" --repos my-org/app --exclude 'my-org/*'
  [ "$status" -eq 2 ]
  [[ "$output" == *"no repos to scan"* ]]
}
