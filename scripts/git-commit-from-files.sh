#!/bin/sh
# Print HEAD's commit hash by reading Git metadata directly, without invoking git.

set -u

short=0
root=.

while [ "$#" -gt 0 ]; do
  case "$1" in
    --short)
      short=1
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "usage: $0 [--short] [repo-root]" >&2
      exit 2
      ;;
    *)
      root=$1
      ;;
  esac
  shift
done

if [ "$#" -gt 0 ]; then
  root=$1
fi

gitdir=$root/.git
if [ -f "$gitdir" ]; then
  IFS= read -r gitdir_line < "$gitdir" || exit 1
  case "$gitdir_line" in
    "gitdir: "*)
      gitdir=${gitdir_line#gitdir: }
      case "$gitdir" in
        /*) ;;
        *) gitdir=$root/$gitdir ;;
      esac
      ;;
    *) exit 1 ;;
  esac
fi

[ -d "$gitdir" ] || exit 1
[ -f "$gitdir/HEAD" ] || exit 1

common=$gitdir
if [ -f "$gitdir/commondir" ]; then
  IFS= read -r commondir < "$gitdir/commondir" || exit 1
  case "$commondir" in
    /*) common=$commondir ;;
    *) common=$gitdir/$commondir ;;
  esac
fi

read_ref() {
  ref=$1
  if [ -f "$gitdir/$ref" ]; then
    IFS= read -r value < "$gitdir/$ref" || return 1
    printf '%s\n' "$value"
    return 0
  fi
  if [ -f "$common/$ref" ]; then
    IFS= read -r value < "$common/$ref" || return 1
    printf '%s\n' "$value"
    return 0
  fi
  if [ -f "$common/packed-refs" ]; then
    while IFS= read -r line; do
      case "$line" in
        "" | "#"* | "^"*) continue ;;
      esac
      set -- $line
      if [ "${2:-}" = "$ref" ]; then
        printf '%s\n' "$1"
        return 0
      fi
    done < "$common/packed-refs"
  fi
  return 1
}

IFS= read -r head < "$gitdir/HEAD" || exit 1
limit=0
while :; do
  case "$head" in
    "ref: "*)
      limit=$((limit + 1))
      [ "$limit" -le 8 ] || exit 1
      ref=${head#ref: }
      head=$(read_ref "$ref") || exit 1
      [ -n "$head" ] || exit 1
      ;;
    *)
      break
      ;;
  esac
done

case "$head" in
  *[!0-9a-fA-F]* | "")
    exit 1
    ;;
esac

if [ "$short" -eq 1 ]; then
  printf '%.7s\n' "$head"
else
  printf '%s\n' "$head"
fi
