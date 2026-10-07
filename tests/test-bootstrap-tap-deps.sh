#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Formula"
cat > "$tmp/Formula/krunkit.rb" <<'RUBY'
depends_on "rust" => :build
depends_on "gvproxy"
depends_on "libkrun"
RUBY
cat > "$tmp/Formula/libkrun.rb" <<'RUBY'
depends_on "libkrunfw"
depends_on "virglrenderer"
depends_on "xz"
RUBY
: > "$tmp/Formula/gvproxy.rb"
: > "$tmp/Formula/libkrunfw.rb"
: > "$tmp/Formula/virglrenderer.rb"

trusted_formulae="|"
found=""
walk() {
  local formula="$1" file dep
  case "$trusted_formulae" in *"|${formula}|"*) return 0 ;; esac
  trusted_formulae="${trusted_formulae}${formula}|"
  found="${found}${formula}\n"
  file="$tmp/Formula/${formula}.rb"
  [[ -f "$file" ]] || return 0
  while IFS= read -r dep; do
    [[ -f "$tmp/Formula/${dep}.rb" ]] || continue
    walk "$dep"
  done < <(sed -nE 's/^[[:space:]]*depends_on[[:space:]]+"([^"]+)".*$/\1/p' "$file")
}
walk krunkit
actual="$(printf '%b' "$found" | sort)"
expected="$(printf '%s\n' gvproxy krunkit libkrun libkrunfw virglrenderer | sort)"
[[ "$actual" == "$expected" ]] || { printf 'unexpected closure:\n%s\n' "$actual" >&2; exit 1; }
echo "bootstrap tap dependency closure test passed"
