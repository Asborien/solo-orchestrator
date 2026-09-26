#!/usr/bin/env bash
# tests/test-helpers/path-without-tool.sh — a PATH on which one tool is absent.
#
# path_without_tool TOOL WORKDIR
#   Prints $PATH with every directory that holds an executable TOOL replaced by
#   a shadow directory under WORKDIR: symlinks to everything in it except TOOL.
#   Every other command resolves as before, so a suite run under the result
#   sees only the one tool missing. rc 1 if a shadow could not be built. The
#   caller must still check `command -v TOOL` fails under the result: a case
#   crediting an absence that never happened is the failure this exists for.
path_without_tool() {
  local tool="$1" work="$2" out="" dir f n=0 old_ifs="$IFS"
  IFS=:
  for dir in $PATH; do
    IFS="$old_ifs"
    [ -n "$dir" ] || continue
    if [ -x "$dir/$tool" ]; then
      n=$((n + 1))
      mkdir -p "$work/shadow$n" || return 1
      for f in "$dir"/*; do
        [ "${f##*/}" = "$tool" ] && continue
        ln -s "$f" "$work/shadow$n/${f##*/}" || return 1
      done
      dir="$work/shadow$n"
    fi
    out="${out:+$out:}$dir"
  done
  IFS="$old_ifs"
  printf '%s\n' "$out"
}
