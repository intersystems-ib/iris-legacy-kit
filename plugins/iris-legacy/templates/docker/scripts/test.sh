#!/usr/bin/env bash
# Run the %UnitTest test classes already compiled in __NS__ (scripts/load.sh compiles them).
#
#   scripts/test.sh                      every test class in package __TEST_PACKAGE__
#   scripts/test.sh A.Test.Class         one class (or any package / class name)
#
# Prints PASS/FAIL per test method, the failing assertions and runtime errors with their
# location, and exits non-zero when anything failed or nothing ran.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && { set -a; . ./.env; set +a; }
NS="${IRIS_NAMESPACE:-__NS__}"; C="${IRIS_CONTAINER:-__NAME__-iris}"
TARGET="${1:-__TEST_PACKAGE__}"

# Read into a variable from a quoted heredoc: no shell expansion inside, and no heredoc nested
# in $(...), which macOS's bash 3.2 mis-parses when the ObjectScript contains single quotes.
read -r -d '' SCRIPT <<'EOS' || true
set ^UnitTestRoot="/tmp/unittest-root/",target="__TARGET__",first=$order(^UnitTest.Result(""),-1)+1
if ##class(%Dictionary.CompiledClass).%ExistsId(target) { set list(target)="" } else { do $SYSTEM.OBJ.GetPackageList(.list,target) }
set cls="" for  { set cls=$order(list(cls)) quit:cls=""  continue:'$classmethod(cls,"%Extends","%UnitTest.TestCase")  set sc=##class(%UnitTest.Manager).DebugRunTestCase("",cls,"/noload/nodelete","") }
write !,"===RESULTS===",!
set (pass,fail)=0
for r=first:1:$order(^UnitTest.Result(""),-1) { set s="" for { set s=$order(^UnitTest.Result(r,s)) quit:s=""  set c="" for { set c=$order(^UnitTest.Result(r,s,c)) quit:c=""  set m="" for { set m=$order(^UnitTest.Result(r,s,c,m),1,mr) quit:m=""  set ok=$listget(mr,1)=1  set:ok pass=pass+1  set:'ok fail=fail+1  write $select(ok:"PASS ",1:"FAIL "),c,":",m,!  write:'ok&($listget(mr,4)'="") "    ",$listget(mr,4),!  if 'ok { set i="" for { set i=$order(^UnitTest.Result(r,s,c,m,i),1,a) quit:i=""  write:'$listget(a,1) "    ",$listget(a,2),": ",$listget(a,3),"  [",$listget(a,4),"]",! } } } } } }
write "TESTS: ",pass," passed, ",fail," failed",!
halt
EOS
SCRIPT="${SCRIPT//__TARGET__/$TARGET}"

# %UnitTest insists on a root directory even when nothing is loaded from disk.
docker exec "$C" mkdir -p /tmp/unittest-root

set +e
out=$(perl -e 'alarm shift; exec @ARGV' 300 docker exec -i "$C" iris session IRIS -U "$NS" <<<"$SCRIPT")
rc=$?
set -e
if [[ $rc == 142 ]]; then
  echo "test: FAILED, the run did not finish within 300 s" >&2
  exit 1
fi
sed -n '/^===RESULTS===/,$p' <<<"$out" | grep -vE "^(===RESULTS===|${NS}>|\s*)\$" || true
summary=$(grep -E '^TESTS: ' <<<"$out" || true)
if [[ -z "$summary" ]]; then
  echo "test: FAILED, no result summary (is $TARGET compiled? run scripts/load.sh)" >&2
  echo "$out" | tail -15 >&2
  exit 1
fi
if [[ "$summary" == "TESTS: 0 passed, 0 failed" ]]; then
  echo "test: FAILED, no test methods ran for $TARGET" >&2
  exit 1
fi
[[ "$summary" == *" 0 failed" ]]
