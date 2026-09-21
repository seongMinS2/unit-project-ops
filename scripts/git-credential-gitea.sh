#!/bin/sh
# git credential helper: answers with GITEA_TOKEN from the environment (never stored on disk).
# Falls back to the Windows *user* environment so sessions started before the variable was set still work.
[ "$1" = "get" ] || exit 0
token="$GITEA_TOKEN"
if [ -z "$token" ]; then
  token=$(powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('GITEA_TOKEN','User')" | tr -d '\r\n')
fi
[ -n "$token" ] || exit 0
echo "username=smpark"
echo "password=$token"
