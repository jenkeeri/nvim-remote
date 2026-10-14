#!/bin/sh
# Stand-in for ssh used by the tests: drops ssh options and the host, then runs
# the "remote" command locally (ssh joins its trailing args with spaces too).
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p|-l|-i|-F) shift 2 ;;
    -*) shift ;;
    *) shift; break ;;
  esac
done
exec sh -c "$*"
