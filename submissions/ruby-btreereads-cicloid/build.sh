#!/usr/bin/env bash
# Runs as a normal user: installs the pinned gems (Gemfile.lock) into vendor/bundle, then builds the
# Lite extension (ext/) with the SQLite amalgamation install.sh unpacked into /opt/sqlite-amalgamation.
# Profile-guided: an instrumented build runs train.rb (the server's Store in the load test's mix) and
# the final build uses that profile.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/ruby/bin:$PATH"
bundle config set --local deployment true
bundle config set --local path vendor/bundle
bundle config set --local force_ruby_platform true
bundle install --jobs 4

# -march=native on x86_64 only, as in install.sh.
NATIVE=""
[ "$(uname -m)" = x86_64 ] && NATIVE="-march=native"
profile="$PWD/ext/pgo"
rm -rf "$profile"
build() { # build <PGO flags>
  (cd ext && NATIVE="$NATIVE" PGO="$1" ruby extconf.rb > /dev/null && make clean > /dev/null && make)
}
build "-fprofile-generate -fprofile-update=single -fprofile-dir=$profile"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bundle exec ruby train.rb "$work/train.db"
build "-fprofile-use -fprofile-partial-training -fprofile-dir=$profile -Wno-missing-profile"
