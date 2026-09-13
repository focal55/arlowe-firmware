#!/usr/bin/env python3
"""Prove every Python import reachable from a shipping unit's Exec* stanza resolves
under the image's own package set.  This is the SC4 gate for phase 07.1.

WHY THIS EXISTS.  build-image.sh's packages guard checks that *declared* packages
landed in the rootfs.  It cannot see an import that was never declared anywhere, and
that blind spot is the whole defect class: python3-yaml and python3-jsonschema were
absent from every image until Phase 7 caught it, because `arlowe_config` imports them
and nothing in the pipeline ever walked from a unit to that import.  Plan 07.1-03's
gate closes the "the file isn't there" half.  This closes the "the import isn't there"
half.

WHAT IT DOES NOT DO, DELIBERATELY.  It never imports a third-party module.  It uses
importlib.util.find_spec, which locates a top-level module without executing it.  A
real import cannot be used here: RPi.GPIO installs cleanly on arm64 and then raises

    RuntimeError: This module can only be run on a Raspberry Pi!

at import time, even in a correctly provisioned container (measured in plan 07.1-01).
A checker built on real imports cannot distinguish "the package is missing" -- the
defect SC4 is about -- from "we are not on a Pi", so it would report a false missing
dependency on every run and the gate would become noise.  find_spec on a TOP-LEVEL
name performs no module execution at all, which is why only top-level names are
probed.

NOTHING HERE IS A MAINTAINED LIST.  The unit set comes from the units directories, the
entry points from each unit's own Exec* lines, the search path from each unit's own
Environment=PYTHONPATH= plus the sys.path calls in the source, the import set from an
AST walk, and the dev-side pins from runtime/*/requirements.txt.  The one exception is
EXCLUSIONS below, which is three lines long and each entry carries an assertion that
has to keep passing for the exclusion to stay valid.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Exclusions.  One entry.  An exclusion that is merely a name is a free pass, so
# each carries a `assert_fn` that must keep returning (True, detail): if the thing
# that justifies the exclusion stops being true, the exclusion is VOID and the
# module is reported as a failure like any other.
# ---------------------------------------------------------------------------


def _whisplay_is_vendored(repo_root: Path) -> "tuple[bool, str]":
    """The WhisPlay driver is not in this repo -- it is vendored into the rootfs at
    image-build time from an external source (provenance is pending todo F2), so no
    interpreter anywhere can resolve it from a checkout.  The exclusion is only
    legitimate while the build step that puts it in the image still exists."""
    chroot = repo_root / "pi-gen/stage-arlowe/01-runtime/00-run-chroot.sh"
    if not chroot.is_file():
        return False, f"{chroot} not found"
    text = chroot.read_text(encoding="utf-8", errors="replace")
    if "WhisPlay.py" in text and "/opt/arlowe/third_party/whisplay-driver" in text:
        return True, f"vendoring step present in {chroot.name}"
    return False, f"no WhisPlay vendoring step found in {chroot}"


EXCLUSIONS = {
    "WhisPlay": _whisplay_is_vendored,
}

# Absolute paths the image uses, mapped back onto the checkout.  Two rules, both
# explicit: a unit's PYTHONPATH and a source file's sys.path call both speak in
# on-device paths, and everything this script reads is a repo path.
def _reroot(path: str, repo_root: Path, runtime: Path) -> "Path | None":
    if path == "/opt/arlowe/runtime":
        return runtime
    if path.startswith("/opt/arlowe/runtime/"):
        return runtime / path[len("/opt/arlowe/runtime/"):]
    if path.startswith("/opt/arlowe/third_party/"):
        return repo_root / "third_party" / path[len("/opt/arlowe/third_party/"):]
    return None


# ---------------------------------------------------------------------------
# systemd unit parsing
# ---------------------------------------------------------------------------

# systemd allows these characters to prefix an Exec* value, changing failure or
# privilege semantics but never the executable.  Strip them before shlex.
_EXEC_PREFIXES = "-+!:@"


class Unit:
    def __init__(self, path: Path):
        self.path = path
        self.name = path.stem
        self.execs: "list[tuple[str, list[str]]]" = []
        self.environment: "dict[str, str]" = {}
        self._parse()

    def _parse(self) -> None:
        for raw in self.path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith(";"):
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            if key == "Environment":
                for item in shlex.split(value):
                    k, _, v = item.partition("=")
                    if k:
                        self.environment[k] = v
            elif key.startswith("Exec"):
                stripped = value.lstrip(_EXEC_PREFIXES).strip()
                if not stripped:
                    continue
                try:
                    tokens = shlex.split(stripped)
                except ValueError:
                    tokens = stripped.split()
                if tokens:
                    self.execs.append((key, tokens))


# ---------------------------------------------------------------------------
# Entry points, derived from the Exec* tokens
# ---------------------------------------------------------------------------


class Entry:
    def __init__(self, unit: Unit, exec_key: str, kind: str, target: str,
                 file: "Path | None", interpreter: str, note: str = ""):
        self.unit = unit
        self.exec_key = exec_key
        self.kind = kind           # "module" | "script" | "skipped"
        self.target = target
        self.file = file
        self.interpreter = interpreter
        self.note = note


def _has_python_shebang(path: Path) -> bool:
    try:
        with path.open("rb") as fh:
            first = fh.readline(256)
    except OSError:
        return False
    return first.startswith(b"#!") and b"python" in first


def entry_points(unit: Unit, repo_root: Path, runtime: Path) -> "list[Entry]":
    """Derive the Python entry points from a unit's own Exec* lines.

    Two shapes reach a Python file, and BOTH are load-bearing:

      1. an explicit interpreter -- `<something>/bin/python -m pkg.mod` or
         `<something>/bin/python /opt/arlowe/runtime/x/y.py`;
      2. a bare executable inside /opt/arlowe/runtime whose SHEBANG is python.

    Shape 2 is not hypothetical and is not covered by a `.py` suffix rule:
    arlowe-identity-init.service runs `/opt/arlowe/runtime/cli/identity init`, a
    python3 script deliberately named without an extension so the CLI symlink
    installer produces `arlowe-identity`.  It is also the single consumer whose
    missing imports (yaml, jsonschema) produced the original defect, so a checker
    that skipped it would skip the case that motivated it.
    """
    out: "list[Entry]" = []
    for key, tokens in unit.execs:
        exe, args = tokens[0], tokens[1:]
        base = os.path.basename(exe)

        if base.startswith("python"):
            module = None
            script = None
            i = 0
            while i < len(args):
                a = args[i]
                if a == "-m" and i + 1 < len(args):
                    module = args[i + 1]
                    break
                if a.startswith("-"):
                    i += 1
                    continue
                script = a
                break
            if module:
                out.append(Entry(unit, key, "module", module, None, exe))
            elif script:
                f = _reroot(script, repo_root, runtime)
                out.append(Entry(unit, key, "script", script, f, exe))
            else:
                out.append(Entry(unit, key, "skipped", exe, None, exe,
                                 "interpreter invoked with no module or script"))
            continue

        f = _reroot(exe, repo_root, runtime)
        if f is not None and f.is_file() and _has_python_shebang(f):
            out.append(Entry(unit, key, "script", exe, f, "#!" + " (shebang)"))
            continue

        reason = "not a Python entry point"
        if f is not None and f.is_file():
            reason = "not a Python entry point (no python shebang)"
        elif f is None:
            reason = "not a Python entry point (outside /opt/arlowe)"
        elif not f.is_file():
            reason = f"not present in the checkout at {f} (built or installed later)"
        out.append(Entry(unit, key, "skipped", exe, f, exe, reason))
    return out


def search_roots(unit: Unit, repo_root: Path, runtime: Path) -> "list[Path]":
    """Roots that the unit itself declares, via Environment=PYTHONPATH=.

    Never hardcoded: arlowe-voice and arlowe-face declare
    /opt/arlowe/runtime:/opt/arlowe/runtime/lib while qwen-tokenizer declares only
    /opt/arlowe/runtime/lib and whisper-stt declares none at all.  That difference
    is exactly the kind of thing that makes one unit start and another not.
    """
    roots: "list[Path]" = []
    for chunk in unit.environment.get("PYTHONPATH", "").split(":"):
        chunk = chunk.strip()
        if not chunk:
            continue
        p = _reroot(chunk, repo_root, runtime)
        if p is not None and p not in roots:
            roots.append(p)
    return roots


# ---------------------------------------------------------------------------
# AST walk
# ---------------------------------------------------------------------------


class Found:
    """One import site."""

    def __init__(self, name: str, top: str, importer: Path, lineno: int,
                 deferred: bool, guarded: bool):
        self.name = name
        self.top = top
        self.importer = importer
        self.lineno = lineno
        self.deferred = deferred
        self.guarded = guarded


def _literal_str(node: ast.AST, consts: "dict[str, str]",
                 env: "dict[str, str]") -> "str | None":
    """Best-effort static evaluation of a path expression.  Handles exactly the three
    shapes the repo uses, and returns None rather than guessing for anything else."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        return consts.get(node.id)
    # os.environ.get("KEY", "default") -- the unit's own Environment= wins when it
    # sets KEY, because on the device that is what the process actually sees.
    if (isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "get"
            and isinstance(node.func.value, ast.Attribute)
            and node.func.value.attr == "environ"
            and node.args
            and isinstance(node.args[0], ast.Constant)
            and isinstance(node.args[0].value, str)):
        key = node.args[0].value
        if key in env:
            return env[key]
        if len(node.args) > 1 and isinstance(node.args[1], ast.Constant) \
                and isinstance(node.args[1].value, str):
            return node.args[1].value
    return None


class Walker:
    def __init__(self, repo_root: Path, runtime: Path, roots: "list[Path]",
                 env: "dict[str, str]"):
        self.repo_root = repo_root
        self.runtime = runtime
        self.roots = list(roots)
        self.env = env
        self.walked: "list[Path]" = []
        self.third: "list[Found]" = []
        # Roots injected by sys.path calls that point OUTSIDE the checkout.  A module
        # resolving only there is vendored at image-build time and cannot be walked
        # from a checkout; recorded so the report can say so instead of calling it
        # an ordinary third-party name.
        self.vendored_roots: "list[tuple[str, Path, Path]]" = []
        self._seen: "set[Path]" = set()

    # -- module resolution --------------------------------------------------

    def _resolve_in(self, root: Path, dotted: str) -> "Path | None":
        parts = dotted.split(".")
        p = root.joinpath(*parts)
        cand = p.with_name(p.name + ".py")
        if cand.is_file():
            return cand
        if (p / "__init__.py").is_file():
            return p / "__init__.py"
        # PEP 420 namespace package.  runtime/ carries no __init__.py anywhere
        # except runtime/lib/tests, so `face.face_service` is only reachable through
        # `face` being a namespace directory.  A bare directory resolves as a
        # package with no source of its own to walk.
        if p.is_dir():
            return p
        return None

    def _resolve(self, dotted: str, current: "Path | None",
                 level: int) -> "tuple[str, Path | None]":
        """Returns (verdict, path).  verdict in {first-party, vendored, third-party}."""
        if level and current is not None:
            base = current.parent
            for _ in range(level - 1):
                base = base.parent
            hit = self._resolve_in(base, dotted) if dotted else base
            if hit is not None:
                return "first-party", hit
            return "third-party", None

        roots = list(self.roots)
        if current is not None and current.parent not in roots:
            # Python puts a script's own directory on sys.path[0].  whisper-stt sets
            # no PYTHONPATH at all, so for stt_server.py this is the ONLY root.
            roots.insert(0, current.parent)
        for root in roots:
            hit = self._resolve_in(root, dotted)
            if hit is None:
                continue
            try:
                hit.relative_to(self.runtime)
                return "first-party", hit
            except ValueError:
                return "vendored", hit
        for _name, _decl, root in self.vendored_roots:
            if not root.exists():
                continue
            hit = self._resolve_in(root, dotted)
            if hit is not None:
                return "vendored", hit
        return "third-party", None

    # -- walking ------------------------------------------------------------

    def walk(self, path: Path) -> None:
        path = path.resolve()
        if path in self._seen or not path.is_file():
            return
        self._seen.add(path)
        try:
            rel = path.relative_to(self.repo_root)
        except ValueError:
            rel = path
        self.walked.append(rel)

        tree = ast.parse(path.read_text(encoding="utf-8", errors="replace"),
                         filename=str(path))
        consts = self._module_consts(tree)
        self._collect_syspath(tree, consts, path)

        for node, deferred, guarded in self._import_sites(tree):
            if isinstance(node, ast.Import):
                pairs = [(a.name, 0) for a in node.names]
            else:
                pairs = [(node.module or "", node.level)]
            for dotted, level in pairs:
                verdict, hit = self._resolve(dotted, path, level)
                if verdict == "first-party" and hit is not None:
                    if hit.is_file():
                        self.walk(hit)
                    continue
                if verdict == "vendored" and hit is not None and hit.is_file():
                    self.walk(hit)
                    continue
                top = dotted.split(".")[0] if dotted else ""
                if not top or top in sys.stdlib_module_names:
                    continue
                self.third.append(Found(dotted, top, rel, node.lineno,
                                        deferred, guarded))

    def _module_consts(self, tree: ast.Module) -> "dict[str, str]":
        """Module-level string assignments, so `sys.path.insert(0, _VAR)` can be
        followed.  runtime/face/face.py assigns the WhisPlay path to a name before
        inserting it, and runtime/cli/identity inlines the call; one mechanism has
        to handle both."""
        consts: "dict[str, str]" = {}
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 \
                    and isinstance(node.targets[0], ast.Name):
                v = _literal_str(node.value, consts, self.env)
                if v is not None:
                    consts[node.targets[0].id] = v
        return consts

    def _collect_syspath(self, tree: ast.Module, consts: "dict[str, str]",
                         source: Path) -> None:
        """sys.path.insert/append with a statically-knowable argument becomes a
        search root, because on the device it really is one.  Generic on purpose:
        face.py injects the WhisPlay vendor directory and runtime/cli/identity
        injects ARLOWE_LIB, and a per-file special case for either would miss the
        next one."""
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            fn = node.func
            if not (isinstance(fn, ast.Attribute) and fn.attr in ("insert", "append")):
                continue
            owner = fn.value
            if not (isinstance(owner, ast.Attribute) and owner.attr == "path"
                    and isinstance(owner.value, ast.Name) and owner.value.id == "sys"):
                continue
            arg = node.args[-1] if node.args else None
            if arg is None:
                continue
            declared = _literal_str(arg, consts, self.env)
            if declared is None:
                continue
            p = _reroot(declared, self.repo_root, self.runtime)
            if p is None:
                continue
            try:
                p.relative_to(self.runtime)
                if p not in self.roots:
                    self.roots.append(p)
            except ValueError:
                rec = (source.name, declared, p)
                if rec not in self.vendored_roots:
                    self.vendored_roots.append(rec)

    @staticmethod
    def _import_sites(tree: ast.Module):
        """Yield (node, deferred, guarded).

        `deferred` means the import runs at CALL time, not start time -- it is
        lexically inside a function.  Only FunctionDef/AsyncFunctionDef defer.  An
        import nested in `try:`, `if:`, `with:` or a class body still executes when
        the module is imported, and that distinction is the whole game here:
        runtime/lib/arlowe_config_validate.py's only real import is
        `from arlowe_config import load` inside a try, and arlowe_config is what
        pulls in yaml and jsonschema -- the two packages that were missing from
        every image.  A checker reading only ast.Module.body would walk past the
        original defect.
        """
        stack = [(tree, False, False)]
        while stack:
            node, in_func, in_guard = stack.pop()
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.Import, ast.ImportFrom)):
                    yield child, in_func, in_guard
                    continue
                child_func = in_func or isinstance(
                    child, (ast.FunctionDef, ast.AsyncFunctionDef))
                child_guard = in_guard or isinstance(
                    child, (ast.Try, ast.If, ast.ExceptHandler))
                stack.append((child, child_func, child_guard))


# ---------------------------------------------------------------------------
# Vendored roots that are absent from the checkout
# ---------------------------------------------------------------------------

_PROVENANCE_IMPORT_HEADING = re.compile(r"to import .* successfully", re.I)
_BULLET_BACKTICK = re.compile(r"^\s*[-*]\s+`([^`]+)`")


def provenance_declared_imports(root: Path) -> "list[str]":
    """A vendored module that is not in the checkout cannot have its own imports
    walked, so an exclusion for it would silently excuse everything it pulls in --
    which for WhisPlay is RPi.GPIO and spidev, two apt packages nothing else in the
    tree imports.  third_party/<x>/PROVENANCE.md declares them in a
    "For <x> to import <y> successfully:" list; parse it, so the graph continues
    through the vendor boundary from a repo source file rather than from a list
    maintained here."""
    prov = root / "PROVENANCE.md"
    if not prov.is_file():
        return []
    names: "list[str]" = []
    active = False
    for line in prov.read_text(encoding="utf-8", errors="replace").splitlines():
        if _PROVENANCE_IMPORT_HEADING.search(line):
            active = True
            continue
        if not active:
            continue
        m = _BULLET_BACKTICK.match(line)
        if not m:
            if line.strip() and not line.lstrip().startswith(("-", "*")):
                break
            continue
        token = m.group(1).strip()
        if token.endswith(".py"):
            continue        # the driver file itself, not one of its dependencies
        names.append(token)
    return names


# ---------------------------------------------------------------------------
# Probing, under the interpreter named on the command line
# ---------------------------------------------------------------------------

_PROBE = r'''
import ast, json, sys
import importlib.util
try:
    import importlib.metadata as md
except Exception:
    md = None

names = json.load(sys.stdin)
try:
    pkg_dists = md.packages_distributions() if md else {}
except Exception:
    pkg_dists = {}

def static_version(origin):
    # Read __version__ out of the SOURCE.  Never exec the module: the point of this
    # whole file is that some of these modules refuse to run off-hardware.
    if not origin or not origin.endswith(".py"):
        return None
    try:
        tree = ast.parse(open(origin, encoding="utf-8", errors="replace").read())
    except Exception:
        return None
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "__version__" \
                        and isinstance(node.value, ast.Constant) \
                        and isinstance(node.value.value, str):
                    return node.value.value
    return None

out = {}
for name in names:
    rec = {"found": False, "origin": None, "version": "unknown",
           "dist": None, "error": None}
    try:
        # find_spec on a TOP-LEVEL name locates the module without executing it.
        spec = importlib.util.find_spec(name)
    except Exception as exc:
        spec = None
        rec["error"] = "%s: %s" % (type(exc).__name__, exc)
    if spec is not None:
        rec["found"] = True
        origin = spec.origin
        if not origin and spec.submodule_search_locations:
            try:
                origin = list(spec.submodule_search_locations)[0]
            except Exception:
                origin = None
        rec["origin"] = origin
        dists = pkg_dists.get(name) or []
        for dist in dists:
            try:
                rec["version"] = md.version(dist)
                rec["dist"] = dist
                break
            except Exception:
                continue
        if rec["version"] == "unknown":
            sv = static_version(origin)
            if sv:
                rec["version"] = sv
                rec["dist"] = rec["dist"] or name
    out[name] = rec

json.dump({"python": sys.executable, "pyversion": sys.version.split()[0],
           "modules": out}, sys.stdout)
'''


def probe(python: str, names: "list[str]") -> dict:
    proc = subprocess.run([python, "-c", _PROBE], input=json.dumps(sorted(names)),
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(
            f"[import-graph] HARD ERROR: probe interpreter {python} failed "
            f"(rc={proc.returncode}).  This is not a missing dependency; the "
            f"interpreter itself could not run the probe.\n{proc.stderr}")
    return json.loads(proc.stdout)


# ---------------------------------------------------------------------------
# Dev-side pins
# ---------------------------------------------------------------------------

def _norm(dist: str) -> str:
    return re.sub(r"[-_.]+", "-", dist).lower()


def dev_pins(repo_root: Path) -> "dict[str, list[tuple[str, str]]]":
    """`==` pins from runtime/*/requirements.txt.  These are the DEV unit's numbers,
    not the image's; the point of comparing is that nothing ever has.

    A distribution can be pinned in several of those files at DIFFERENT versions --
    numpy is 2.3.5 in runtime/face and runtime/voice but the dev units were
    calibrated separately -- so every pin is kept.  Reporting only the first file
    found would turn a multi-file disagreement into one arbitrary line."""
    pins: "dict[str, list[tuple[str, str]]]" = {}
    for req in sorted((repo_root / "runtime").glob("*/requirements.txt")):
        for raw in req.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.split("#", 1)[0].strip()
            if "==" not in line or line.startswith("-"):
                continue
            name, _, ver = line.partition("==")
            ver = ver.split(";")[0].strip()
            name = re.sub(r"\[.*\]", "", name).strip()
            if name and ver:
                pins.setdefault(_norm(name), []).append(
                    (ver, str(req.relative_to(repo_root))))
    return pins


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--units", action="append", required=True,
                    help="directory of *.service files (repeatable)")
    ap.add_argument("--runtime", required=True, help="the runtime/ source tree")
    ap.add_argument("--python", required=True,
                    help="interpreter to resolve third-party modules under")
    ap.add_argument("--unit", action="append", default=[],
                    help="restrict to these unit names (repeatable)")
    ap.add_argument("--repo-root", default=".")
    args = ap.parse_args()

    repo_root = Path(args.repo_root).resolve()
    runtime = Path(args.runtime).resolve()

    unit_files: "list[Path]" = []
    for d in args.units:
        p = Path(d)
        if not p.is_dir():
            print(f"[import-graph] HARD ERROR: units directory not found: {p}",
                  file=sys.stderr)
            return 2
        unit_files.extend(sorted(p.glob("*.service")))
    if args.unit:
        wanted = set(args.unit)
        unit_files = [f for f in unit_files
                      if f.stem in wanted or f.name in wanted]
    if not unit_files:
        print("[import-graph] HARD ERROR: no unit files selected", file=sys.stderr)
        return 2

    pins = dev_pins(repo_root)

    failures: "list[str]" = []
    warns: "list[str]" = []
    deferred_report: "list[str]" = []
    excluded_seen: "dict[str, str]" = {}
    probed_total = 0

    print("=" * 78)
    print(f"[import-graph] probe interpreter : {args.python}")
    print(f"[import-graph] runtime tree      : {runtime}")
    print(f"[import-graph] units             : "
          f"{', '.join(sorted(f.stem for f in unit_files))}")
    print("=" * 78)

    for unit_file in unit_files:
        unit = Unit(unit_file)
        entries = entry_points(unit, repo_root, runtime)
        py_entries = [e for e in entries if e.kind != "skipped"]

        print()
        print(f"=== unit: {unit.name} ===")
        for e in entries:
            if e.kind == "skipped":
                print(f"  SKIP-ENTRY {e.exec_key}={e.target}  -- {e.note}")

        if not py_entries:
            print("  no Python entry points")
            continue

        roots = search_roots(unit, repo_root, runtime)
        walker = Walker(repo_root, runtime, roots, unit.environment)

        for e in py_entries:
            if e.kind == "module":
                verdict, hit = walker._resolve(e.target, None, 0)
                if verdict != "first-party" or hit is None:
                    failures.append(
                        f"{unit.name}: entry module {e.target!r} does not resolve "
                        f"under the unit's own PYTHONPATH "
                        f"({unit.environment.get('PYTHONPATH', '<unset>')})")
                    print(f"  FAIL-ENTRY [module] {e.target}: unresolvable")
                    continue
                e.file = hit
            if e.file is None or not e.file.is_file():
                failures.append(
                    f"{unit.name}: entry script {e.target!r} not found at "
                    f"{e.file} in the checkout")
                print(f"  FAIL-ENTRY [script] {e.target}: missing at {e.file}")
                continue
            print(f"  ENTRY [{e.kind}] {e.exec_key}={e.target}"
                  f" -> {e.file.relative_to(repo_root)}")
            walker.walk(e.file)

        print(f"  search roots: "
              f"{', '.join(str(r.relative_to(repo_root)) for r in walker.roots) or '(none declared; script dir only)'}")
        for src, declared, path in walker.vendored_roots:
            has_src = path.is_dir() and any(path.glob("*.py"))
            state = ("Python source present; walked directly" if has_src
                     else "no Python source in the checkout; imports continued "
                          "from PROVENANCE.md")
            shown = path.relative_to(repo_root) if path.exists() else path
            print(f"  vendor root: {declared} (injected by {src}) -> {shown}"
                  f" [{state}]")

        print(f"  first-party modules walked ({len(walker.walked)}):")
        for w in walker.walked:
            print(f"    {w}")

        # Continue the graph through a vendored root whose Python source is not in
        # the checkout, using that vendor's own PROVENANCE.md declaration, so an
        # exclusion is never a free pass for everything the vendored module pulls
        # in.  The trigger is the absence of any *.py in the root, NOT the absence
        # of the directory: third_party/whisplay-driver is committed (INSTALL.md,
        # PROVENANCE.md) while WhisPlay.py itself is user-supplied, so a
        # `path.exists()` test would silently skip the one case this exists for.
        # If WhisPlay.py is ever committed, Walker._resolve finds and walks it and
        # this fallback stops firing on its own.
        vendor_extra: "list[Found]" = []
        for src, declared, path in walker.vendored_roots:
            if path.is_dir() and any(path.glob("*.py")):
                continue
            for name in provenance_declared_imports(path):
                top = name.split(".")[0]
                vendor_extra.append(
                    Found(name, top,
                          Path(f"{path.name}/PROVENANCE.md (declared)"), 0,
                          False, False))

        start_time = [f for f in walker.third if not f.deferred] + vendor_extra
        deferred = [f for f in walker.third if f.deferred]

        checkable: "dict[str, list[Found]]" = {}
        for f in start_time:
            if f.top in EXCLUSIONS:
                ok, detail = EXCLUSIONS[f.top](repo_root)
                if ok:
                    excluded_seen[f.top] = detail
                    continue
                failures.append(
                    f"{unit.name}: exclusion for {f.top!r} is VOID -- {detail}")
            checkable.setdefault(f.top, []).append(f)
        for f in deferred:
            checkable.setdefault(f.top, []).append(f)

        if not checkable:
            print("  third-party modules: none")
            continue

        result = probe(args.python, list(checkable))
        mods = result["modules"]
        probed_total += len(checkable)

        print(f"  third-party modules ({len(checkable)}), resolved under "
              f"{result['python']} (python {result['pyversion']}):")
        for top in sorted(checkable):
            rec = mods[top]
            sites = checkable[top]
            defer_only = all(s.deferred for s in sites)
            site = sites[0]
            where = f"{site.importer}:{site.lineno}" if site.lineno else str(site.importer)
            if len(sites) > 1:
                where += f" (+{len(sites) - 1} more)"
            tag = "OK  " if rec["found"] else ("DEFER-MISS" if defer_only else "MISS")
            # A version column that prints "unknown" for an unresolved module reads
            # like a drift result.  It is not one: nothing was found to version.
            ver = rec["version"] if rec["found"] else "-"
            dist = f" dist={rec['dist']}" if rec["dist"] else ""
            print(f"    {tag:<10} {top:<18} {ver:<12}{dist:<24} <- {where}")
            if rec["error"]:
                print(f"               probe error: {rec['error']}")

            if not rec["found"]:
                msg = (f"{unit.name}: {top} does not resolve under {args.python} "
                       f"(imported at {where})")
                if defer_only:
                    deferred_report.append(msg + " [function-local: fails at call "
                                                 "time, not start time]")
                else:
                    failures.append(msg)
                continue
            if defer_only:
                deferred_report.append(
                    f"{unit.name}: {top} is imported function-locally at {where} "
                    f"(resolves now, but is not covered by start-up)")

            dist_key = _norm(rec["dist"] or top)
            for pin_ver, pin_file in (pins.get(dist_key) or pins.get(_norm(top)) or []):
                if rec["version"] != "unknown" and pin_ver != rec["version"]:
                    warns.append(f"{top}: image {rec['version']} vs dev pin "
                                 f"{pin_ver} ({pin_file})")

        if deferred:
            print(f"  function-local imports ({len(deferred)}) -- run at call time, "
                  f"not at start-up:")
            for f in deferred:
                print(f"    {f.name} <- {f.importer}:{f.lineno}")

    print()
    print("=" * 78)
    if excluded_seen:
        print("EXCLUSIONS APPLIED:")
        for name, detail in sorted(excluded_seen.items()):
            print(f"  {name}: {detail}")
    else:
        print("EXCLUSIONS APPLIED: none")

    print(f"WARN total: {len(warns)}")
    for w in warns:
        print(f"  WARN {w}")

    print(f"FUNCTION-LOCAL notes: {len(deferred_report)}")
    for d in deferred_report:
        print(f"  NOTE {d}")

    print(f"probed {probed_total} third-party module reference(s); "
          f"{len(failures)} failure(s)")
    if failures:
        print()
        for f in failures:
            print(f"  FAIL {f}")
        print("[import-graph] FAIL: an import reachable from a unit entry point "
              "does not resolve under this interpreter.  Declare its package in "
              "pi-gen/stage-arlowe/00-packages/00-packages-nr or in "
              "pi-gen/stage-arlowe/01-runtime/files/venv-requirements/.")
        return 1
    print("[import-graph] OK: every import reachable from a unit entry point "
          "resolves under this interpreter.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
