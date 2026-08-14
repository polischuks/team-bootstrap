#!/usr/bin/env bash
# check-version-sync.sh — version-consistency gate. Fails when the project's declared version-bearing
# fields DISAGREE. Targets the concrete drift this framework hit twice (v2.12.1, v2.17.0): `VERSION`
# bumped, but `.claude-plugin/plugin.json` / `marketplace.json` left stale — so the plugin self-reports
# the wrong version and `claude plugin update` offers nothing.
#
# Version-location set:
#   - Default (a plugin: `.claude-plugin/plugin.json` exists): `VERSION` (trimmed), plugin.json `version`,
#     and EVERY `"version"` in `marketplace.json` (metadata.version + each plugins[].version).
#   - Else an AGENTS.md/CLAUDE.md `VersionFiles:` contract — a space/comma list of `path` (whole trimmed
#     file) or `path:key` (first `"key":"…"` in that file). For non-plugin projects.
#   - Neither ⇒ skip + WARN (no version locations — never a false block, quality-gate parity).
# All collected values must be byte-equal; any divergence ⇒ exit 1, naming every location + value and
# the plurality value (report truth — the human bumps; no auto-fix). jq-free (anchored grep/sed).
#
# Marker-gated ⇒ in-session (CI has no .runs/ marker), like check-tdd/check-delivery/check-diff-coverage.
#
# Usage: bin/check-version-sync.sh [project-dir]  ·  bin/check-version-sync.sh --self-test
# Exit:  0 in sync / skip · 1 versions disagree · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

_doc() { local f; for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; }
_plain() { head -1 "$1" 2>/dev/null | tr -d '[:space:]'; }
# _json_versions FILE LABEL → emit "LABEL\t<value>" for each "version":"…" in FILE (metadata + plugins[]).
_json_versions() {
  grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null \
    | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' | while IFS= read -r v; do [ -n "$v" ] && printf '%s\t%s\n' "$2" "$v"; done
}
# _json_key FILE KEY → first "key":"value"
_json_key() { grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/'; }

# _collect → emit "source\tvalue" for every version-bearing field (empty if no locations)
_collect() {
  if [ -f .claude-plugin/plugin.json ]; then
    [ -f VERSION ] && printf 'VERSION\t%s\n' "$(_plain VERSION)"
    _json_versions .claude-plugin/plugin.json ".claude-plugin/plugin.json"
    [ -f .claude-plugin/marketplace.json ] && _json_versions .claude-plugin/marketplace.json ".claude-plugin/marketplace.json"
    return 0
  fi
  local doc vf ent path key val
  doc="$(_doc)"; [ -n "$doc" ] || return 0
  vf="$(grep -iE "^[[:space:]]*[-*]?[[:space:]]*VersionFiles:" "$doc" 2>/dev/null | head -1 | sed -E 's/^[^:]*://' | tr ',' ' ' | tr -d '`')"
  [ -n "$vf" ] || return 0
  for ent in $vf; do
    case "$ent" in
      *:*) path="${ent%%:*}"; key="${ent#*:}"; [ -f "$path" ] && val="$(_json_key "$path" "$key")" && [ -n "$val" ] && printf '%s\t%s\n' "$ent" "$val" ;;
      *)   [ -f "$ent" ] && val="$(_plain "$ent")" && [ -n "$val" ] && printf '%s\t%s\n' "$ent" "$val" ;;
    esac
  done
}

_evaluate() {
  local marker mk collected distinct
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-version-sync: no active delivery run — skipping (governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-version-sync: marker not intends_code — skipping."; return 0; }

  collected="$(_collect)"
  if [ -z "$collected" ]; then
    echo "check-version-sync: WARN — no version locations to check (no .claude-plugin/plugin.json and no AGENTS.md VersionFiles:). Unenforceable — declare VersionFiles: to enforce." >&2
    return 0
  fi
  distinct="$(printf '%s\n' "$collected" | cut -f2 | sort -u | grep -c .)"
  if [ "$distinct" -le 1 ]; then
    echo "check-version-sync: all version fields agree ($(printf '%s\n' "$collected" | head -1 | cut -f2)) — OK."
    return 0
  fi
  local plurality
  plurality="$(printf '%s\n' "$collected" | cut -f2 | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
  {
    echo "  FAIL: version fields DISAGREE — a release must not bump one and leave the others stale (the v2.12.1/v2.17.0 drift):"
    printf '%s\n' "$collected" | while IFS="$(printf '\t')" read -r src val; do printf '    %-42s %s\n' "$src" "$val"; done
    echo "    → plurality value is '${plurality}'; bring every field to the intended version."
  } >&2
  return 1
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.claude-plugin" "$T/.runs/r"
  printf '{"run":"r","intends_code":true,"source":"harness"}\n' > "$T/.runs/r/RUN"
  _run() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-version-sync.sh" . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }
  mkmani() { # VERSION PLUGVER METAVER PVER1 [PVER2]
    printf '%s\n' "$1" > "$T/VERSION"
    printf '{"name":"x","version":"%s"}\n' "$2" > "$T/.claude-plugin/plugin.json"
    if [ -n "${5:-}" ]; then
      printf '{"metadata":{"version":"%s"},"plugins":[{"name":"a","version":"%s"},{"name":"b","version":"%s"}]}\n' "$3" "$4" "$5" > "$T/.claude-plugin/marketplace.json"
    else
      printf '{"metadata":{"version":"%s"},"plugins":[{"name":"a","version":"%s"}]}\n' "$3" "$4" > "$T/.claude-plugin/marketplace.json"
    fi
  }
  # AC-2 — all four agree → pass
  mkmani 2.17.0 2.17.0 2.17.0 2.17.0; _chk "all fields agree → pass" "$(_run)" 0
  # AC-1 — the exact v2.17.0 drift: VERSION ahead, manifests stale → fail
  mkmani 2.17.0 2.16.0 2.16.0 2.16.0; _chk "VERSION 2.17 but manifests 2.16 (the real drift) → fail" "$(_run)" 1
  # AC-3 — one plugins[] entry diverges → fail (per-entry, not just first)
  mkmani 2.17.0 2.17.0 2.17.0 2.17.0 2.16.0; _chk "one plugins[] entry stale → fail" "$(_run)" 1
  # AC-6 — marker-less → skip
  ( cd "$T" && rm -f .runs/r/RUN ); _chk "no active marker → skip" "$(_run)" 0
  printf '{"run":"r","intends_code":true,"source":"harness"}\n' > "$T/.runs/r/RUN"
  # AC-4 — generic project via VersionFiles: (no .claude-plugin) — agree → pass, disagree → fail
  rm -rf "$T/.claude-plugin"; rm -f "$T/VERSION" "$T/.claude-plugin/marketplace.json" 2>/dev/null
  printf '{"version":"1.4.0"}\n' > "$T/package.json"; printf 'version = "1.4.0"\n' > "$T/pyproject_ver"
  printf '# AGENTS\n\n- VersionFiles: `package.json:version`, `pyproject_ver`\n' > "$T/AGENTS.md"
  printf '1.4.0\n' > "$T/pyproject_ver"
  _chk "VersionFiles: two files agree → pass" "$(_run)" 0
  printf '1.5.0\n' > "$T/pyproject_ver"
  _chk "VersionFiles: two files disagree → fail" "$(_run)" 1
  # AC-5 — no plugin, no VersionFiles → skip+WARN
  ( cd "$T" && printf '# AGENTS\n\n- Lint: `true`\n' > AGENTS.md )
  _chk "no version locations → skip+WARN (exit 0)" "$(_run)" 0
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-version-sync --self-test: OK"; exit 0; fi
  echo "check-version-sync --self-test: $fail case(s) FAILED" >&2; exit 1
fi

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-version-sync: bad dir '$root'" >&2; exit 64; }
if _evaluate; then exit 0; else exit 1; fi
