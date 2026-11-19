#!/usr/bin/env bash
# Load and compile every .cls/.mac/.inc/.int file of the source directories (sourceDirs in
# .claude/iris-legacy.json) into namespace __NS__. The repo is the source of truth; this is the
# bulk path (start, reset). Single edits reach IRIS through the kit's edit hook.
#
# Exits non-zero if anything fails to load or compile, or if IRIS imports fewer documents than
# there are files.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && { set -a; . ./.env; set +a; }
NS="${IRIS_NAMESPACE:-__NS__}"; C="${IRIS_CONTAINER:-__NAME__-iris}"
dirs=(); while IFS= read -r d; do [[ -n "$d" && -d "$d" ]] && dirs+=("$d"); done < <(jq -r '.sourceDirs[]?' .claude/iris-legacy.json)
((${#dirs[@]})) || { echo "load: no source directories in .claude/iris-legacy.json" >&2; exit 1; }

files=$(find "${dirs[@]}" -type f \( -name '*.cls' -o -name '*.mac' -o -name '*.inc' -o -name '*.int' \) | wc -l | tr -d ' ')
[[ "$files" != 0 ]] || { echo "load: no ObjectScript files in ${dirs[*]}"; exit 0; }

# Copy this checkout's source directories into the container (docker cp keeps the host uid, so
# clean up and hand the files to irisowner as root).
STAGE=/tmp/kit-load
docker exec -u root "$C" sh -c "rm -rf $STAGE && mkdir -p $STAGE"
for d in "${dirs[@]}"; do
  docker exec -u root "$C" mkdir -p "$STAGE/$d"
  docker cp -q "$d/." "$C:$STAGE/$d"
done
docker exec -u root "$C" chown -R irisowner:irisowner "$STAGE"

# ImportDir, not LoadDir: LoadDir has no wildcard argument and skips .mac/.inc/.int.
# /checkuptodate=none: import and compile everything, so a reload never keeps a stale document.
read -r -d '' SCRIPT <<'EOS' || true
set sc=$SYSTEM.OBJ.ImportDir("/tmp/kit-load","*.cls;*.mac;*.inc;*.int","ck/checkuptodate=none",.errlog,1,.imported)
set n=0,k="" for  set k=$order(imported(k)) quit:k=""  set n=n+1
write !,"IMPORTED:",n,!
write "ERRORS:",+$get(errlog),!
write "LOADRESULT:",$select($system.Status.IsOK(sc):"OK",1:$system.Status.GetErrorText(sc)),!
halt
EOS

set +e
out=$(perl -e 'alarm shift; exec @ARGV' 300 docker exec -i "$C" iris session IRIS -U "$NS" <<<"$SCRIPT")
rc=$?
set -e
[[ $rc != 142 ]] || { echo "load: FAILED, no answer from IRIS within 300 s" >&2; exit 1; }
echo "$out" | grep -vE '^\s*$' | grep -vE "^(${NS}>|Node:|Instance:)" || true

imported=$(sed -n 's/^IMPORTED://p' <<<"$out")
if ! grep -q '^LOADRESULT:OK' <<<"$out" || ! grep -q '^ERRORS:0$' <<<"$out"; then
  echo "load: FAILED (see errors above)" >&2; exit 1
fi
if [[ "$imported" != "$files" ]]; then
  echo "load: FAILED, $files files in ${dirs[*]} but IRIS imported ${imported:-0}" >&2; exit 1
fi
echo "load: OK ($imported documents)"
