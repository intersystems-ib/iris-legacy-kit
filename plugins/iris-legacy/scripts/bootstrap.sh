#!/usr/bin/env bash
# Set a customer's IRIS code repository up for the kit: the steps of /iris-legacy:bootstrap.
# Every step works on the project root ($CLAUDE_PROJECT_DIR, else the current directory) and
# never commits anything.
#
#   bootstrap.sh detect
#       What is there: ObjectScript files and where, files to convert, test classes, the error
#       trap, existing Claude and IRIS config, free ports. JSON on stdout; changes nothing.
#   bootstrap.sh convert [--apply]
#       Routine files without a ROUTINE header (.rtn, .m, headerless .mac/.int) get one and become
#       .mac; routines in Studio XML exports are extracted. Without --apply, only lists what it
#       would do. Classes in XML exports and %RO files need IRIS; it lists them.
#   bootstrap.sh write --mode docker|existing [options]
#       Write the connection file, the kit config, the CLAUDE.md block, .claude/settings.json and
#       .gitignore lines; in docker mode also the stack (compose file, image, gateway, scripts/).
#       Existing files are kept (CLAUDE.md gets its block replaced, settings.json is merged).
#         --namespace NS        required for existing; docker default: from the project name
#         --host HOST           existing only (required)
#         --web-port PORT       existing: required; docker: default the first free 46080+100k
#         --web-prefix PREFIX   existing: when Atelier is at /PREFIX/api/atelier/
#         --scheme http|https   existing: default http
#         --source-dir DIR      repeatable; default: the directories detect found
#         --test-package PKG    default: the package of the test classes detect found
#         --name NAME           docker: compose project and container prefix; default: the folder name
#         --iris-tag TAG        docker: IRIS image tag; default 2026.2
#         --publish DIR=CMD     repeatable: after an edit under DIR, run CMD from the project root
#                               (for example ui=scripts/ui.sh to publish a web UI)
#         --not-production      the namespace or host only looks like production (e.g. PRODUCTS):
#                               pass it only after the user has confirmed that
#   bootstrap.sh prove
#       Tools installed, Atelier REST and the namespace answer, a probe routine compiles through
#       the edit hook, a broken one comes back as a hook error; the probe is deleted again.
#   bootstrap.sh baseline
#       Counts of the static findings in the code as it is (ascot by code, smells by rule, global
#       references), into .claude/iris-legacy-baseline.json, so later reports can be read against them.
set -uo pipefail
. "$(dirname "$0")/common.sh"
TPL="$KIT/templates"
MODE_ARG="${1:-}"; shift || true

die() { echo "bootstrap: $*" >&2; exit 1; }
say() { echo "bootstrap: $*"; }

# ---------------------------------------------------------------------------------------------
# File discovery. Paths are relative to ROOT; tool, VCS, dependency and stack folders are skipped.
list_files() {
  (cd "$ROOT" && find . \( -name .git -o -name node_modules -o -name .claude -o -name docker \
     -o -name .venv -o -name .tools -o -name .test-data \) -prune -o -type f -print 2>/dev/null) | sed 's#^\./##'
}

first_code_line() { awk 'NF { print; exit }' "$ROOT/$1" 2>/dev/null; }

has_header() {  # routine file starts with "ROUTINE NAME"
  first_code_line "$1" | grep -qiE '^ROUTINE[[:space:]]+[%A-Za-z0-9.]+'
}

is_studio_xml() { head -c 2000 "$ROOT/$1" 2>/dev/null | grep -q '<Export generator='; }

# ---------------------------------------------------------------------------------------------
detect() {
  local all f ext top
  local mac="" cls="" headerless="" xml="" ro="" rootfiles=""
  all=$(list_files)
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    ext=$(tr '[:upper:]' '[:lower:]' <<<"${f##*.}")
    case "$ext" in
      mac|int|inc) if has_header "$f"; then mac+="$f"$'\n'; else headerless+="$f"$'\n'; fi ;;
      rtn|m) headerless+="$f"$'\n' ;;
      cls) cls+="$f"$'\n' ;;
      ro|rsa|rou) ro+="$f"$'\n' ;;
      xml) is_studio_xml "$f" && xml+="$f"$'\n' ;;
      *) continue ;;
    esac
    [[ "$f" == */* ]] || rootfiles+="$f"$'\n'
  done <<<"$all"

  # Source directories: the top-level folders that hold ObjectScript in a form the hooks take.
  local dirs
  dirs=$(printf '%s%s' "$mac" "$cls" | awk -F/ 'NF > 1 { print $1 }' | sort -u)

  # Test classes and their common package.
  local tests="" pkg=""
  if [[ -n "$cls" ]]; then
    tests=$(while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      grep -qiE '^Class[[:space:]]+[%A-Za-z0-9.]+[[:space:]]+Extends[[:space:](]+[^{]*%UnitTest\.TestCase' "$ROOT/$f" &&
        sed -nE 's/^Class[[:space:]]+([%A-Za-z0-9.]+).*/\1/p' "$ROOT/$f" | head -1
    done <<<"$cls")
    pkg=$(awk 'NF { n = split($0, p, "."); if (!seen++) { m = n - 1; for (i = 1; i <= m; i++) c[i] = p[i] }
                    else { k = 0; for (i = 1; i <= m && i < n; i++) { if (c[i] != p[i]) break; k = i } m = k } }
               END { s = ""; for (i = 1; i <= m; i++) s = s (i > 1 ? "." : "") c[i]; print s }' <<<"$tests")
  fi

  # Error trap and log: the most used $ZTRAP/$ETRAP target; %ETN means ^ERRORS.
  local code trap etn ucaret
  code=$(printf '%s%s' "$mac" "$headerless" | while IFS= read -r f; do [[ -n "$f" ]] && cat "$ROOT/$f"; done)
  trap=$(grep -oiE '\$Z?T(RAP)?="[^"]+"' <<<"$code" | sed -E 's/^[^"]*"//; s/"$//' | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')
  etn=false; grep -qiE '(BACK|LOG)\^%ETN' <<<"$code" && etn=true
  # U="^": labels that use U as the $PIECE delimiter expect it set at sign-on.
  ucaret=false; grep -qiE '\$P(IECE)?\([^,()]+,U[,)]' <<<"$code" && ucaret=true

  # Existing setup.
  local ex=()
  for f in CLAUDE.md .iris-agentic-dev.toml .claude/iris-legacy.json .claude/settings.json .mcp.json docker-compose.yml; do
    [[ -e "$ROOT/$f" ]] && ex+=("$f")
  done

  jq -n \
    --arg root "$ROOT" \
    --argjson git "$(git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && echo true || echo false)" \
    --arg name "$(project_name)" \
    --arg dirs "$dirs" --arg mac "$mac" --arg cls "$cls" --arg headerless "$headerless" \
    --arg xml "$xml" --arg ro "$ro" --arg rootfiles "$rootfiles" --arg tests "$tests" --arg pkg "$pkg" \
    --arg trap "$trap" --argjson etn "$etn" --argjson ucaret "$ucaret" \
    --arg existing "$(printf '%s\n' ${ex[@]+"${ex[@]}"})" \
    --arg ports "$(free_ports)" '
    def lines: split("\n") | map(select(length > 0));
    {
      root: $root, git: $git, name: $name,
      sourceDirs: ($dirs | lines),
      files: { routines: ($mac | lines | length), classes: ($cls | lines | length) },
      convert: { headerless: ($headerless | lines), studioXml: ($xml | lines), roExports: ($ro | lines) },
      atRepoRoot: ($rootfiles | lines),
      tests: { classes: ($tests | lines), package: $pkg },
      errors: { trap: $trap, etn: $etn },
      uCaret: $ucaret,
      existing: ($existing | lines),
      dockerPorts: ($ports | split(" ") | {web: (.[0] | tonumber? // null), superserver: (.[1] | tonumber? // null)})
    }'
}

project_name() {  # a compose-safe name from the folder name
  basename "$ROOT" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-30
}

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

free_ports() {  # the first pair 46080+100k / 46972+100k with both ports free
  local k w s
  for k in $(seq 0 20); do
    w=$((46080 + 100 * k)); s=$((46972 + 100 * k))
    port_free "$w" && port_free "$s" && { echo "$w $s"; return; }
  done
}

# ---------------------------------------------------------------------------------------------
convert() {
  local apply=false f name dest
  [[ "${1:-}" == --apply ]] && apply=true
  local d; d=$(detect) || exit 1
  local n=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    name=$(basename "$f"); name=${name%.*}
    dest="${f%.*}.mac"
    if $apply; then
      [[ -e "$ROOT/$dest" && "$dest" != "$f" ]] && { echo "skip  $f: $dest exists"; continue; }
      { printf 'ROUTINE %s\n' "$name"; cat "$ROOT/$f"; } >"$ROOT/$dest.tmp" && mv "$ROOT/$dest.tmp" "$ROOT/$dest"
      [[ "$dest" != "$f" ]] && { git -C "$ROOT" rm -q --cached "$f" 2>/dev/null; rm -f "$ROOT/$f"; }
      echo "added header  $f -> $dest (ROUTINE $name)"
    else
      echo "would add a ROUTINE $name header: $f -> $dest"
    fi
    n=$((n + 1))
  done < <(jq -r '.convert.headerless[]' <<<"$d")

  # Studio XML: <Routine name="X" type="MAC|INC|INT"><![CDATA[...]]></Routine> can be extracted
  # as is; <Class> elements are not UDL and need IRIS to convert.
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local outdir; outdir="$(dirname "$f")/$(basename "${f%.*}")"
    if $apply; then
      mkdir -p "$ROOT/$outdir"
      awk -v out="$ROOT/$outdir" '
        match($0, /<Routine name="[^"]+" type="[A-Za-z]+"/) {
          s = substr($0, RSTART, RLENGTH); split(s, q, "\""); name = q[2]; type = tolower(q[4])
          file = out "/" name "." type; print "ROUTINE " name (type == "mac" ? "" : " [Type=" toupper(type) "]") > file
          sub(/.*<!\[CDATA\[/, ""); inr = 1
          if ($0 == "") next
        }
        inr {
          line = $0; endr = sub(/\]\]><\/Routine>.*/, "", line)
          if (line != "" || !endr) print line > file
          if (endr) { inr = 0; close(file); print "extracted " file }
        }' "$ROOT/$f" | sed "s#$ROOT/##"
    else
      echo "would extract the routines of $f into $outdir/ ($(grep -c '<Routine name=' "$ROOT/$f") routines)"
    fi
    local nc; nc=$(grep -c '<Class name=' "$ROOT/$f")
    [[ $nc -gt 0 ]] && echo "needs IRIS: $f has $nc classes in XML form (load it into IRIS, then export UDL; see the bootstrap skill)"
    n=$((n + 1))
  done < <(jq -r '.convert.studioXml[]' <<<"$d")

  while IFS= read -r f; do
    [[ -n "$f" ]] && echo "needs IRIS: $f is a %RO export (load it into IRIS, then export UDL; see the bootstrap skill)"
  done < <(jq -r '.convert.roExports[]' <<<"$d")
  [[ $n -gt 0 ]] || echo "nothing to convert"
}

# ---------------------------------------------------------------------------------------------
# Anything with "prod" or "prd" in it, "live" as a word, or %SYS. Deliberately broad: a false
# alarm costs one confirmed flag (--not-production), a miss compiles edits into production.
looks_like_production() { grep -qiE 'pro?d|(^|[^a-z])live([^a-z]|$)|^%sys$' <<<"$1"; }

# render SRC DEST MODE: copy a template, substituting the tokens and keeping only the sections
# for MODE (<!--docker-->...<!--/docker-->, <!--existing-->..., <!--etn--> when ETN=true).
render() {
  local src=$1 dest=$2 mode=$3
  awk -v mode="$mode" -v etn="$ETN" '
    /^<!--(docker|existing|etn)-->$/ { tag = substr($0, 5, length($0) - 7); keep = (tag == mode || (tag == "etn" && etn == "true")); skip = !keep; next }
    /^<!--\/(docker|existing|etn)-->$/ { skip = 0; next }
    !skip' "$src" |
  sed -e "s|__NAME__|$NAME|g" -e "s|__NS__|$NS|g" -e "s|__WEB_PORT__|$WEB_PORT|g" \
      -e "s|__SS_PORT__|$SS_PORT|g" -e "s|__IRIS_TAG__|$IRIS_TAG|g" -e "s|__HOST__|$HOST|g" \
      -e "s|__TEST_PACKAGE__|$TEST_PKG|g" -e "s|__ERROR_TRAP__|$ERR_TRAP|g" \
      -e "s|__SRC_DIRS__|$SRC_LIST|g" -e "s|__WHERE__|$WHERE|g" -e "s|__U_NOTE__|$U_NOTE|g" >"$dest"
}

wrote=() kept=()
put() {  # put TEMPLATE DEST [MODE]: render unless DEST exists
  local dest="$ROOT/$2"
  if [[ -e "$dest" ]]; then kept+=("$2"); return; fi
  mkdir -p "$(dirname "$dest")"
  render "$1" "$dest" "${3:-$MODE}"
  [[ -x "$1" ]] && chmod +x "$dest"
  wrote+=("$2")
}

write() {
  MODE="" NS="" HOST="" WEB_PORT="" SS_PORT="" PREFIX="" SCHEME="http" TEST_PKG="" NAME="" IRIS_TAG="2026.2"
  local dirs=() notprod=false pubs=()
  while (($#)); do
    case "$1" in
      --not-production) notprod=true; shift; continue ;;
      --mode) MODE=$2 ;;
      --namespace) NS=$2 ;;
      --host) HOST=$2 ;;
      --web-port) WEB_PORT=$2 ;;
      --web-prefix) PREFIX=$2 ;;
      --scheme) SCHEME=$2 ;;
      --source-dir) dirs+=("${2%/}") ;;
      --test-package) TEST_PKG=$2 ;;
      --name) NAME=$2 ;;
      --iris-tag) IRIS_TAG=$2 ;;
      --publish) [[ "$2" =~ ^[A-Za-z0-9._/-]+=.+$ ]] || die "--publish DIR=COMMAND"; pubs+=("$2") ;;
      *) die "unknown option $1" ;;
    esac
    shift 2 || die "$1 needs a value"
  done
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "$ROOT is not a git repository. Put the code under git first, so every change the kit and Claude make can be reviewed and undone."

  local d; d=$(detect)
  ((${#dirs[@]})) || while IFS= read -r x; do [[ -n "$x" ]] && dirs+=("$x"); done < <(jq -r '.sourceDirs[]' <<<"$d")
  ((${#dirs[@]})) || die "no source directory: no ObjectScript with headers in a folder. Run 'bootstrap.sh convert' first, or pass --source-dir."
  for x in "${dirs[@]}"; do
    [[ -d "$ROOT/$x" && "$x" != . && "$x" != /* && "$x" != *..* ]] || die "--source-dir $x: not a folder inside the project"
  done
  [[ -n "$NAME" ]] || NAME=$(jq -r .name <<<"$d")
  [[ -n "$TEST_PKG" ]] || TEST_PKG=$(jq -r '.tests.package' <<<"$d")
  ERR_TRAP=$(jq -r '.errors.trap' <<<"$d"); ETN=$(jq -r '.errors.etn' <<<"$d")
  [[ -n "$ERR_TRAP" ]] || ERR_TRAP="the trap label"

  case "$MODE" in
    docker)
      [[ -n "$NS" ]] || NS=$(tr 'a-z-' 'A-Z_' <<<"$NAME" | tr -cd 'A-Z0-9_' | cut -c1-20)
      if [[ -z "$WEB_PORT" ]]; then read -r WEB_PORT SS_PORT <<<"$(jq -r '"\(.dockerPorts.web) \(.dockerPorts.superserver)"' <<<"$d")"; fi
      [[ -n "$SS_PORT" && "$SS_PORT" != null ]] || SS_PORT=$((WEB_PORT + 892))
      HOST=localhost
      WHERE="in a development IRIS in Docker (\`scripts/up.sh\`)" ;;
    existing)
      [[ -n "$NS" && -n "$HOST" && -n "$WEB_PORT" ]] || die "existing mode needs --namespace, --host and --web-port"
      WHERE="on the shared development instance \`$HOST\`" ;;
    *) die "--mode docker|existing" ;;
  esac
  [[ -n "$TEST_PKG" ]] || TEST_PKG="$NS.Test"

  if ! $notprod && { looks_like_production "$NS" || looks_like_production "$HOST"; }; then
    die "'$NS' on '$HOST' looks like production. The kit compiles every edit into the namespace it is given: point it at a development namespace (or, if the user confirms it is not production, pass --not-production)."
  fi
  # Validate everything that goes into files, so substitution is safe and nothing odd is written.
  [[ "$NS" =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]] || die "namespace '$NS': letters, digits, - and _ only"
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,29}$ ]] || die "name '$NAME': lower-case letters, digits and - only"
  [[ "$WEB_PORT" =~ ^[0-9]{1,5}$ && "$SS_PORT$MODE" =~ ^([0-9]{1,5}docker|existing)$ ]] || die "ports must be numbers"
  [[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "host '$HOST': a host name or address"
  [[ "$PREFIX" =~ ^[A-Za-z0-9_/-]*$ && "$SCHEME" =~ ^https?$ ]] || die "bad --web-prefix or --scheme"
  [[ "$TEST_PKG" =~ ^[%A-Za-z][A-Za-z0-9.]*$ ]] || die "test package '$TEST_PKG'"
  [[ "$IRIS_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "iris tag '$IRIS_TAG'"
  local trap_re='^[%A-Za-z0-9^ .]+$'
  [[ "$ERR_TRAP" =~ $trap_re ]] || ERR_TRAP="the trap label"
  SRC_LIST=$(printf '`%s/`, ' "${dirs[@]}"); SRC_LIST=${SRC_LIST%, }
  U_NOTE=""; [[ "$(jq -r .uCaret <<<"$d")" == true ]] && U_NOTE='. Labels that use `U` as the `$PIECE` delimiter expect `U="^"`, which the sign-on code sets: set it too'

  # The connection file. Docker: the dev stack's fixed credentials. Existing: none in the file.
  if [[ -e "$ROOT/.iris-agentic-dev.toml" ]]; then kept+=(.iris-agentic-dev.toml); else
    {
      echo "# Where the kit's MCP server and edit hook connect. Written by /iris-legacy:bootstrap."
      echo "# This file wins over IRIS_* environment variables for the keys it sets."
      echo "host = \"$HOST\""
      echo "web_port = $WEB_PORT"
      [[ -n "$PREFIX" ]] && echo "web_prefix = \"$PREFIX\""
      [[ "$SCHEME" != http ]] && echo "scheme = \"$SCHEME\""
      echo "namespace = \"$NS\""
      if [[ $MODE == docker ]]; then
        echo "# Dev-only credentials of the local Docker stack."
        echo "username = \"_SYSTEM\""
        echo "password = \"SYS\""
        echo "container = \"$NAME-iris\""
      else
        echo "# No credentials here: each developer sets IRIS_USERNAME and IRIS_PASSWORD in"
        echo "# .claude/settings.local.json (gitignored). Without IRIS_PASSWORD, iris-interop-dev"
        echo "# falls back to a default password, so bootstrap.sh prove refuses to run without it."
      fi
    } >"$ROOT/.iris-agentic-dev.toml"
    wrote+=(.iris-agentic-dev.toml)
  fi

  # The kit config.
  if [[ -e "$CONF" ]]; then kept+=(.claude/iris-legacy.json); else
    mkdir -p "$ROOT/.claude"
    local pubjson; pubjson=$(printf '%s\n' ${pubs[@]+"${pubs[@]}"} | jq -Rn '[inputs | select(length > 0) | capture("^(?<dir>[^=]+)=(?<command>.+)$")]')
    jq -n --args --arg mode "$MODE" --arg pkg "$TEST_PKG" --arg trap "$(jq -r .errors.trap <<<"$d")" \
      --argjson etn "$ETN" --arg c "$NAME-iris" --argjson pub "$pubjson" '{
        sourceDirs: $ARGS.positional,
        environment: $mode,
        tests: { package: $pkg },
        errors: ({ trap: (if $trap == "" then null else $trap end), log: (if $etn then "^ERRORS" else null end) } | with_entries(select(.value != null))),
        lint: { ascot: true, smells: true },
        toolset: "routines"
      } + (if $pub == [] then {} else { publish: $pub } end)
        + (if $mode == "docker" then { container: $c } else {} end)' "${dirs[@]}" >"$CONF"
    wrote+=(.claude/iris-legacy.json)
  fi

  # CLAUDE.md: replace the kit block, or append it; create the file when there is none.
  local block; block=$(mktemp); render "$TPL/CLAUDE-block.md" "$block" "$MODE"
  if [[ -f "$ROOT/CLAUDE.md" ]] && grep -q '^<!-- iris-legacy:begin' "$ROOT/CLAUDE.md"; then
    awk -v b="$block" '/^<!-- iris-legacy:begin/ { while ((getline l < b) > 0) print l; skip = 1; next }
                       /^<!-- iris-legacy:end -->/ { skip = 0; next } !skip' "$ROOT/CLAUDE.md" >"$ROOT/CLAUDE.md.tmp" &&
      mv "$ROOT/CLAUDE.md.tmp" "$ROOT/CLAUDE.md"
    wrote+=("CLAUDE.md (kit block replaced)")
  elif [[ -f "$ROOT/CLAUDE.md" ]]; then
    { echo; cat "$block"; } >>"$ROOT/CLAUDE.md"; wrote+=("CLAUDE.md (kit block appended)")
  else
    { echo "# $NAME"; echo; echo "<!-- What the application does, for whoever works on it: fill in. -->"; echo; cat "$block"; } >"$ROOT/CLAUDE.md"
    wrote+=(CLAUDE.md)
  fi
  rm -f "$block"

  # .claude/settings.json: the marketplace and plugin for teammates, and the permissions.
  local repo s="$ROOT/.claude/settings.json"
  repo=$(jq -r '.repository' "$KIT/.claude-plugin/plugin.json" | sed -E 's#^https://github.com/##; s#\.git$##')
  [[ -f "$s" ]] || echo '{}' >"$s"
  jq --arg repo "$repo" --slurpfile p "$TPL/permissions.json" '
    .extraKnownMarketplaces["iris-legacy-kit"] = { source: { source: "github", repo: $repo } }
    | .enabledPlugins["iris-legacy@iris-legacy-kit"] = true
    | .permissions.allow = (((.permissions.allow // []) + $p[0].allow) | unique)
    | .permissions.deny = (((.permissions.deny // []) + $p[0].deny) | unique)' "$s" >"$s.tmp" && mv "$s.tmp" "$s"
  wrote+=(".claude/settings.json (merged)")

  # .gitignore lines.
  local g="$ROOT/.gitignore" line added=0
  touch "$g"
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    grep -qxF "$line" "$g" && continue
    # The heading only once: a line that a later kit version adds goes at the end, without a second heading.
    [[ $added == 0 ]] && ! grep -qxF '# iris-legacy kit' "$g" && printf '\n# iris-legacy kit\n' >>"$g"
    echo "$line" >>"$g"; added=1
  done < <(cat "$TPL/gitignore"; [[ $MODE == docker ]] && cat "$TPL/gitignore-docker")
  [[ $added == 1 ]] && wrote+=(".gitignore (lines added)")

  # The Docker stack.
  if [[ $MODE == docker ]]; then
    local t rel
    while IFS= read -r t; do
      rel=${t#"$TPL/docker/"}
      [[ "$rel" == env.example ]] && rel=.env.example
      put "$t" "$rel"
    done < <(find "$TPL/docker" -type f | sort)
  fi

  # Other IRIS servers that start beside the kit's: the project's .mcp.json, and the user and local
  # scopes in Claude Code's own config. The deny rules from the permissions template hide the
  # standard names; any other name is for the user to remove or deny.
  local cc="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" others denied name where
  iris_servers() {  # iris_servers WHERE < JSON with .mcpServers: "NAME<TAB>WHERE" per IRIS server
    jq -r --arg w "$1" '.mcpServers // {} | to_entries[]
      | select(((.value.command // "") + " " + ((.value.args // []) | join(" "))) | test("iris"; "i"))
      | "\(.key)\t\($w)"' 2>/dev/null
  }
  others=$({
    [[ -f "$ROOT/.mcp.json" ]] && iris_servers .mcp.json <"$ROOT/.mcp.json"
    [[ -f "$cc" ]] && iris_servers "user scope" <"$cc"
    [[ -f "$cc" ]] && jq --arg r "$ROOT" '.projects[$r] // {}' "$cc" 2>/dev/null | iris_servers "local scope"
  })
  denied=$(jq -r '.deny[] | select(startswith("mcp__")) | ltrimstr("mcp__")' "$TPL/permissions.json")

  echo "Written:"; printf '  %s\n' "${wrote[@]}"
  ((${#kept[@]})) && { echo "Kept (already there, not changed):"; printf '  %s\n' "${kept[@]}"; }
  while IFS=$'\t' read -r name where; do
    [[ -n "$name" ]] || continue
    if grep -qxF "$name" <<<"$denied"; then
      echo "Note: the IRIS MCP server $name ($where) also starts here; the deny rule in .claude/settings.json hides its tools, so Claude sees only the kit's."
    else
      echo "Note: the IRIS MCP server $name ($where) also starts here, and the kit provides one. Remove it, or add \"mcp__$name\" to permissions.deny in .claude/settings.json."
    fi
  done <<<"$others"
  if [[ $MODE == existing ]]; then
    echo "Next: each developer sets IRIS_USERNAME and IRIS_PASSWORD in .claude/settings.local.json:"
    echo '  { "env": { "IRIS_USERNAME": "...", "IRIS_PASSWORD": "..." } }   (then restart Claude Code)'
  else
    echo "Next: scripts/up.sh (Docker must be running), then bootstrap.sh prove."
  fi
  echo "Nothing is committed: review with git status and git diff."
}

# ---------------------------------------------------------------------------------------------
toml() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"#[:space:]])\"?.*/\1/p" "$ROOT/.iris-agentic-dev.toml" | head -1; }

prove() {
  local fails=0
  ok() { echo "PASS $1"; }
  no() { echo "FAIL $1"; fails=$((fails + 1)); }
  [[ -f "$ROOT/.iris-agentic-dev.toml" && -f "$CONF" ]] || die "run 'bootstrap.sh write' first"

  CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-}" "$KIT/scripts/setup.sh" --check >/dev/null 2>&1 &&
    ok "tools installed" || { no "tools installed (run /iris-legacy:setup)"; echo "TESTS: $fails failed"; return 1; }

  local host port ns user pass prefix scheme base
  host=$(toml host); port=$(toml web_port); ns=$(toml namespace); prefix=$(toml web_prefix); scheme=$(toml scheme)
  user=$(toml username); user=${user:-${IRIS_USERNAME:-}}
  pass=$(toml password); pass=${pass:-${IRIS_PASSWORD:-}}
  if [[ -z "$pass" || -z "$user" ]]; then
    no "credentials: set IRIS_USERNAME and IRIS_PASSWORD (in .claude/settings.local.json, then restart Claude Code); without them iris-interop-dev falls back to defaults"
    echo "TESTS: $fails failed"; return 1
  fi
  base="${scheme:-http}://$host:$port${prefix:+/$prefix}/api/atelier"
  # Credentials on stdin (curl -K -), never on the command line.
  cred() { local u=${user//\\/\\\\} p=${pass//\\/\\\\}; u=${u//\"/\\\"}; p=${p//\"/\\\"}; printf 'user = "%s:%s"\n' "$u" "$p"; }
  http() { cred | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "$@"; }

  local c
  c=$(http "$base/"); [[ $c == 200 ]] && ok "Atelier REST answers at $base" || no "Atelier REST at $base: HTTP $c (000: not reachable; 401: credentials; 404: no /api on that web server)"
  c=$(http "$base/v1/$ns/docnames/CLS"); [[ $c == 200 ]] && ok "namespace $ns" || no "namespace $ns: HTTP $c"
  [[ $fails == 0 ]] || { echo "TESTS: $fails failed"; return 1; }

  # The probe goes through the plugin's edit hook exactly as Claude Code calls it.
  local dir name file payload out rc
  dir=$(source_dirs | head -1); name="ZZKITPROBE$$"; file="$ROOT/$dir/$name.mac"
  [[ -e "$file" ]] && die "$file exists"
  PROBE_FILE=$file; trap 'rm -f "${PROBE_FILE:-}"' EXIT
  payload=$(jq -nc --arg f "$file" --arg c "$ROOT" '{hook_event_name: "PostToolUse", tool_name: "Write", tool_input: {file_path: $f}, cwd: $c}')
  printf 'ROUTINE %s\n%s ; iris-legacy kit probe, deleted again by bootstrap.sh prove\n quit\n' "$name" "$name" >"$file"
  out=$("$KIT/scripts/post-edit.sh" <<<"$payload" 2>&1); rc=$?
  [[ $rc == 0 && "$out" == *"no errors"* ]] && ok "a probe routine compiles through the edit hook" || no "probe compile: rc=$rc $out"
  printf 'ROUTINE %s\n%s ; iris-legacy kit probe\n set x=(1\n quit\n' "$name" "$name" >"$file"
  out=$("$KIT/scripts/post-edit.sh" <<<"$payload" 2>&1); rc=$?
  [[ $rc == 2 && "$out" == *"$name"* ]] && ok "a compile error comes back as a hook error (exit 2)" || no "broken probe: rc=$rc $out"
  c=$(http -X DELETE "$base/v1/$ns/doc/$name.mac")
  [[ $c == 200 ]] && ok "probe deleted from $ns" || no "probe delete: HTTP $c (delete $name.mac by hand)"
  rm -f "$file"
  echo "TESTS: $fails failed"
  [[ $fails == 0 ]]
}

# ---------------------------------------------------------------------------------------------
baseline() {
  [[ -f "$CONF" ]] || die "run 'bootstrap.sh write' first"
  local dirs=() d ascot smells gm out="$ROOT/.claude/iris-legacy-baseline.json"
  while IFS= read -r d; do [[ -n "$d" ]] && dirs+=("$d"); done < <(source_dirs)
  ascot=$("$KIT/scripts/lint.sh" 2>/dev/null | grep -oE '^(error|warning|information|hint): .*\[A[0-9]+\]' | grep -oE 'A[0-9]+' | sort | uniq -c |
          awk '{ printf "%s\"%s\":%s", (NR > 1 ? "," : ""), $2, $1 }')
  if [[ -x "$BIN/ast-grep" ]]; then
    smells=$(cd "$ROOT" && "$BIN/ast-grep" scan -c "$(sg_config)" --custom-languages allow --json=compact "${dirs[@]}" 2>/dev/null |
             jq -c 'group_by(.ruleId) | map({key: .[0].ruleId, value: length}) | from_entries')
  fi
  gm=$("$KIT/scripts/globalmap.sh" --json 2>/dev/null | jq -c '{files: (.files | length), references: (.references | length),
        globals: (.references | map(select(.glob != "")) | group_by(.glob) | map({key: .[0].glob, value: length}) | from_entries)}')
  jq -n --argjson a "{${ascot}}" --argjson s "${smells:-null}" --argjson g "${gm:-null}" \
    --arg date "$(date +%Y-%m-%d)" --slurpfile v "$KIT/versions.json" '{
      date: $date,
      tools: ($v[0] | with_entries(.value = .value.version)),
      ascot: $a, smells: $s, globalMap: $g
    }' >"$out"
  say "baseline written to ${out#"$ROOT"/}"
  jq . "$out"
}

case "$MODE_ARG" in
  detect) detect ;;
  convert) convert "$@" ;;
  write) write "$@" ;;
  prove) prove ;;
  baseline) baseline ;;
  *) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
