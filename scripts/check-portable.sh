#!/usr/bin/env bash
# Deny account-, region- and host-specific literals in tracked files, so a fresh
# checkout is not quietly steered at the account this was built in.
#
# The rule differs by file kind: code must not STEER a user at one account or
# region, docs must not DISPLAY identifiers. Instance types are denied in docs
# only -- there is no GPU type left in runtime-selection code, and the system node
# group's m7i.xlarge setting is neither account- nor region-specific
# (docs/PRODUCTION-CHECKLIST.md tracks making it a variable).
#
# A second class, disclosure vocabulary (VOCAB), is denied with NO hatch:
# those phrases describe the account this was built in, never the reader's. It
# runs on every file in PATHS -- skip_path exemptions included -- and its hits
# are tagged "disclosure:" so a failure says which rule fired.
#
# Escape hatches, both counted so they cannot grow silently:
#   # portable-ok: <reason>          this line (code or prose)
#   <!-- portable-ok: <reason> -->   the next fenced block, or the next line if
#                                    no fence follows immediately (docs only)
#
# The block hatch exists because recorded sample output inherently contains the
# region it was recorded in, and a <REGION>-ised measurement describes nowhere.
# A one-line hatch cannot serve that: a `#` inside a fence would render.
#
# Does NOT catch snippet drift or semantic hardcodes like an AZ-count
# assumption. It is a literal scanner, not a portability proof. A VOCAB phrase
# that wraps across lines surfaces only once that file's per-line hits are
# cleared -- the file fails either way, the second pass names the rest.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# README.md is named explicitly: it is at the root, so the `docs` entry misses
# the one page every reader opens.
PATHS=(terraform scripts k8s docker Makefile README.md docs)

# Generated/gitignored files, or provider hashes whose 12-digit runs are false
# hits. Curated capture fixtures are intentionally scanned with release files.
skip_path() {
  case "$1" in
    *config.env|*.auto.tfvars|*backend.hcl|*.terraform*) return 0 ;;
    scripts/check-portable.sh) return 0 ;;   # the rules themselves
    # Dated design records: they quote the identifiers they specify away -- the
    # token table, an EXPECTED_ACCOUNT= example. VOCAB still scans them.
    docs/superpowers/specs/*) return 0 ;;
  esac
  return 1
}

EVERYWHERE='[0-9]{12}|ap-northeast-2|ap-south-1|cr-[0-9a-f]{17}|i-[0-9a-f]{17}|profile *= *"ai"'
DOCS_ONLY='g6e\.|g5\.|g6\.|g7e\.|p4d\.|p5\.|m7i\.'
# Public evidence needs a tighter identity boundary than normal source: these
# shapes are useful only after tokenisation. Placeholders start with "<", so
# service endpoints such as api.wandb.ai and s3.amazonaws.com remain legal.
CAPTURE_IDS='arn:(aws|aws-us-gov|aws-cn):[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:[^[:space:]"]+|arn:(aws|aws-us-gov|aws-cn):s3:::[a-z0-9][a-z0-9.-]{2,62}|[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}|(^|[^[:alnum:]_])i-([0-9a-f]{8}|[0-9a-f]{17})([^[:alnum:]_]|$)|ip-([0-9]{1,3}-){3}[0-9]{1,3}\.[a-z0-9-]+\.compute\.internal|(^|[^0-9])(10\.([0-9]{1,3}\.){2}[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)|s3://[a-z0-9][a-z0-9.-]{2,62}|https://wandb\.ai/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'
CAPTURE_NAMES='Karpenter-[A-Za-z0-9._-]+|nanochat-base-train-[a-z0-9]{5}|gpu-nanochat(-[a-z0-9]{5})?|podName=[a-z0-9]|"hostNodeName"[[:space:]]*:[[:space:]]*"[a-z0-9]|"(NodeClaim|Node|NodePool)"[^}]*"name"[[:space:]]*:[[:space:]]*"[a-z0-9]|"resourceVersion"[[:space:]]*:[[:space:]]*"[0-9]+"|workflows\.argoproj\.io/trace-id[^0-9a-f]+[0-9a-f]{32}|"?bucket"?[[:space:]]*[=:][[:space:]]*"?[a-z0-9][a-z0-9.-]{2,62}|"?queue"?[[:space:]]*[=:][[:space:]]*"?[A-Za-z0-9][A-Za-z0-9._/-]*|wandb: Currently logged in as: [^<[:space:]]+|wandb: setting up run [a-z0-9]{8}'

fail=0 exempt=0 scanned=0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "check-portable FAILED -- this is not a Git checkout" >&2
  exit 1
}

tracked="$(git ls-files "${PATHS[@]}")" || {
  echo "check-portable FAILED -- could not list tracked files" >&2
  exit 1
}
[ -n "$tracked" ] || {
  echo "check-portable FAILED -- no tracked release files found" >&2
  exit 1
}

untracked="$(git ls-files --others --exclude-standard "${PATHS[@]}")" || {
  echo "check-portable FAILED -- could not list untracked files" >&2
  exit 1
}
if [ -n "$untracked" ]; then
  echo "check-portable FAILED -- release files are not tracked:" >&2
  printf '%s\n' "$untracked" >&2
  exit 1
fi

# shellcheck disable=SC2094
while IFS= read -r f; do
  skip_path "$f" && continue
  scanned=$((scanned + 1))
  pat="$EVERYWHERE"
  case "$f" in *.md) pat="$pat|$DOCS_ONLY" ;; esac
  case "$f" in docs/captures/*) pat="$pat|$CAPTURE_IDS|$CAPTURE_NAMES" ;; esac

  n=0 infence=0 blockok=0
  while IFS= read -r line; do
    n=$((n + 1))

    # Track fenced blocks, and whether this one was exempted just above it.
    case "$f" in *.md)
      case "$line" in
        '```'*) if [ "$infence" = 1 ]; then infence=0; blockok=0
                else infence=1; fi; continue ;;
        *'<!-- portable-ok:'*) blockok=1; exempt=$((exempt + 1)); continue ;;
      esac
      # Covers the next fenced block, or -- if the pending hatch meets a prose
      # line first -- that line, then clears. One hatch, one exemption.
      if [ "$blockok" = 1 ]; then
        [ "$infence" = 1 ] && continue
        case "$line" in '') continue ;; *) blockok=0; continue ;; esac
      fi
    esac

    # Must be a COMMENT marker, not the bare words: prose that documents the
    # portable-ok hatch would otherwise count itself as an exemption.
    case "$line" in
      *'# portable-ok:'*|*'<!-- portable-ok:'*) exempt=$((exempt + 1)); continue ;;
    esac

    hit="$(printf '%s' "$line" | grep -oE "$pat" | head -1 || true)"
    [ -z "$hit" ] || { printf '%s:%d: %s\n' "$f" "$n" "$hit"; fail=1; }
  done < "$f"
done <<< "$tracked"

# ------------------------------------------------------ disclosure vocabulary --
# Deny the claim about OUR posture, not the noun: a reader naming their own Spot
# quota is legitimate and necessary, "the Spot quota cannot be raised" is ours.
VOCAB='isengard|internal account|Spot-G|spot quota cannot|unraisable|cannot be raised|not a cheat|really run'

# No portable-ok for this class -- an exemption for disclosure language is the
# disclosure. This pass therefore runs OUTSIDE skip_path: a token table is a
# reason to tolerate a region literal, not a sentence about our account. The two
# files it does skip are structural, not editorial -- this script defines the
# patterns, and the spec that introduced them quotes the sentences it deletes.
while IFS= read -r f; do
  case "$f" in
    scripts/check-portable.sh|docs/superpowers/specs/*educational-handoff*) continue ;;
  esac
  hits="$(grep -inoE "$VOCAB" "$f" || true)"
  if [ -n "$hits" ]; then
    while IFS=: read -r ln phrase; do
      printf '%s:%s: disclosure: %s\n' "$f" "$ln" "$phrase"
    done <<< "$hits"
    fail=1
  else
    # Prose wraps, and a per-line grep cannot see "Why it is not / a cheat". Fold
    # the file to one line to catch it -- dropping each line's leading comment or
    # list marker first, or the continuation's own `#` lands mid-phrase. Only
    # reached when nothing matched per-line, so the common case keeps its line
    # numbers; here the phrase is still caught and only the number is lost.
    w="$(sed -E 's@^[[:space:]]*(#+|//+|\*|--)?[[:space:]]*@@' "$f" \
         | tr -s '[:space:]' ' ' | grep -ioE "$VOCAB" | sort -u | tr '\n' ' ' || true)"
    [ -z "$w" ] || { printf '%s: disclosure, wrapped across lines: %s\n' "$f" "$w"; fail=1; }
  fi
done <<< "$tracked"

printf '\n%d files scanned, %d line(s)/block(s) exempted via portable-ok\n' "$scanned" "$exempt"
if [ "$fail" = 0 ]; then
  echo "check-portable OK"
else
  echo "check-portable FAILED -- tokenise the literals above, or justify one with"
  echo "'portable-ok: <reason>'. Lines tagged 'disclosure' have no hatch: reword them."
fi
exit "$fail"
