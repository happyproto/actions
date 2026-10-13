# shellcheck shell=bash
# Shared by the test/*.test.sh files: a tiny runner and assertions.
# Each test is a function; `run_tests` calls every function named test_*,
# each in a subshell with a fresh $WORK directory, and exits non-zero if any
# failed.

fail() {
  echo "    $*" >&2
  exit 1
}

assert_eq() { # expected actual [label]
  [[ "$1" == "$2" ]] || fail "${3:-value}: expected [$1], got [$2]"
}

assert_contains() { # haystack needle [label]
  [[ "$1" == *"$2"* ]] || fail "${3:-text}: [$1] does not contain [$2]"
}

assert_not_contains() { # haystack needle [label]
  [[ "$1" != *"$2"* ]] || fail "${3:-text}: [$1] contains [$2]"
}

run_tests() {
  local failed=0 name
  for name in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    if (WORK=$(mktemp -d) && cd "$WORK" && "$name"); then
      echo "ok   $name"
    else
      echo "FAIL $name"
      failed=1
    fi
  done
  return "$failed"
}
