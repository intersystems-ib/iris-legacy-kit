---
name: bootstrap
description: Set up a repository of legacy InterSystems IRIS code (routines, globals, classes) for Claude Code with the kit - find the code, convert headerless or exported routines, connect to a Docker or an existing development IRIS, write CLAUDE.md, the connection file, the kit config and the project settings, prove the compile-on-edit loop, and record a baseline of the static findings. Use when the user asks to bootstrap, onboard or set up a project for the IRIS legacy kit, or when the kit's hooks say the project has no .claude/iris-legacy.json.
---

# Bootstrap a project for the IRIS legacy kit

The kit's hooks and MCP server act only in a project that has a connection file
(`.iris-agentic-dev.toml`) and a kit config (`.claude/iris-legacy.json`). This skill writes
them, with the rest of the setup, by running one script step by step and asking the user what
only they can decide. **It commits nothing**: the user reviews the result with `git diff`.

All steps run the same script, from the project root:

```bash
S="${CLAUDE_PLUGIN_ROOT}/scripts/bootstrap.sh"
export CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
```

(Set both variables in the same command as each call: shell state does not carry over.)

## 1. Find the code

Run `"$S" detect` and summarise its JSON for the user in a few lines: how many routines and
classes, in which folders (`sourceDirs`), test classes and their package, the error trap, and
what is already there (`existing`).

- `git: false`: stop. Ask the user to put the code under git first; every change the kit and
  Claude make must be reviewable and reversible.
- `atRepoRoot` not empty: ObjectScript at the top of the repo cannot be a source directory.
  Propose moving it into `src/` (with `git mv`), and do it only if the user agrees.
- `existing` lists `.iris-agentic-dev.toml` or `.claude/iris-legacy.json`: the project was
  bootstrapped before. The write step keeps those files; go to step 4 unless the user wants to
  start over (then they move the files away themselves).

## 2. Convert what the hooks cannot take

The hooks take `.mac`, `.int`, `.inc` and `.cls` files that start with a `ROUTINE NAME` or
`Class` line. If `convert` in the detect output is not empty, run `"$S" convert` (it only lists),
show the list, and run `"$S" convert --apply` when the user agrees:

- routine files without a header (`.rtn`, `.m`, headerless `.mac`) get `ROUTINE <file name>`
  and become `.mac`. Check one or two: the routine name must match what callers use
  (`DO ^NAME`); rename the file if it does not.
- routines in Studio XML exports are extracted next to the export.
- **Classes in XML exports and `%RO` files need IRIS.** Once IRIS runs (step 4), load the file
  and export UDL: copy it into the container (Docker) or to a path the server can read, then with
  `iris_execute`: `do $system.OBJ.Load("/path/file.xml","-d")` and, for each document,
  `do $system.OBJ.ExportUDL("Pkg.Class.cls","/path/out/Pkg/Class.cls")`. Copy the UDL files
  into the source directory, and tell the user which files came from where.

## 3. Ask where IRIS runs

Ask the user (one question, two options):

- **Docker**: the kit generates a development IRIS (Community by default; licensed with an
  `iris.key`) and a Web Gateway, on free ports, plus `scripts/up.sh`, `down.sh`, `load.sh`,
  `check.sh`, `test.sh`, `iris.sh`. Needs Docker. The namespace defaults to the project name.
- **An existing development instance**: ask for the host, the web server port (the one that
  serves `/api/atelier`, e.g. 80, 443 or 52773), an optional URL prefix, http or https, and the
  namespace. **Never ask for the password in the conversation.**

Then run, for example:

```bash
"$S" write --mode docker
"$S" write --mode existing --host iris-dev.example --web-port 443 --scheme https --namespace APPDEV
```

Optional: `--source-dir DIR` (repeat; default the detected folders), `--test-package PKG`,
`--name NAME` and `--iris-tag TAG` (Docker). The script refuses a namespace or host that looks
like production (`prod`, `prd`, `live`, `%SYS`). If the user confirms that it is not production
(a namespace such as `PRODUCTS`), add `--not-production`; never add it on your own.

Show the user the list the script prints (written and kept). The kit provides the project's IRIS
server, and the settings it writes hide the tools of a server named `iris-interop-dev` or
`iris-agentic-dev`. If it notes another IRIS server (in `.mcp.json`, or at user or local scope),
pass its advice on: remove that server, or add the deny rule it names. Two servers show Claude
the same tools twice.

## 4. Bring IRIS up and prove the loop

- Docker: `scripts/up.sh` (it builds the image the first time, a few minutes; tell the user).
- Existing instance: each developer puts their credentials in `.claude/settings.local.json`,
  which is gitignored and which the generated settings stop you from reading:

  ```json
  { "env": { "IRIS_USERNAME": "their user", "IRIS_PASSWORD": "their password" } }
  ```

  Ask the user to add it themselves, then to **restart Claude Code** (the environment, the MCP
  server and the hooks read it at session start) and run this skill again; it continues here.

Then `"$S" prove`. It checks the tools, Atelier REST, the namespace, that a probe routine
compiles through the kit's edit hook and that a broken one comes back as a hook error, and
deletes the probe from IRIS again. Each FAIL line says what to fix.

Finally, check the loop as you will meet it: create `<first source dir>/ZZKITCHECK.mac` with the
Write tool, containing a `ROUTINE ZZKITCHECK` line and a deliberate syntax error such as
` set x=(1`. The compile hook must answer with an error for that file. Delete the file, and
delete `ZZKITCHECK.mac` from IRIS with `iris_doc` (mode delete). If no hook answered, the plugin
is not enabled in this session: check `/plugin`, then restart.

## 5. Record the baseline

`"$S" baseline` writes `.claude/iris-legacy-baseline.json`: ascot findings by code, legacy smells
by rule, and global references by global, for the code as it is. The edit hooks report only what
an edit adds; this file says what was there before, for planning (for example: every
`goto-label-offset` is a hazard to pin with a characterization test before a refactor).

## 6. Hand over

Run `git status` and `git diff --stat`, and tell the user:

- what was written, and that nothing is committed;
- the `CLAUDE.md` block (between the `iris-legacy:begin` and `end` markers) is regenerated by a
  later bootstrap; project notes go outside it, and the top of a new `CLAUDE.md` waits for a
  paragraph on what the application does;
- teammates get the kit from `.claude/settings.json` (marketplace and plugin) when they open the
  project; on an existing instance each of them adds their own credentials (step 4);
- a suggested next step: `iris-legacy:map-globals` to document the data model, or
  `iris-legacy:characterize` before changing a routine.
