#!/usr/bin/env python3
"""
gen_tasks.py - turn data/tasks/*.json into the table TaskRunner reads.

The JSON is the source of truth: the host validates achievements and drives the
campaign from it, and CI checks it. The guest needs the same facts in a form
HolyC can compile, so this writes guest/Game/Tasks.HC rather than having the
guest parse JSON - there is no JSON parser in TempleOS and writing one to hold
four integers would be silly.

Usage:
    python tools/gen_tasks.py            # regenerate guest/Game/Tasks.HC
    python tools/gen_tasks.py --check    # fail if the file is out of date
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TASK_DIR = os.path.join(ROOT, "data", "tasks")
OUT = os.path.join(ROOT, "guest", "Game", "Tasks.HC")

ID_MAX = 32
NAME_MAX = 32
PATH_MAX = 64
MAX_CASES = 8
EXPECT_MAX = 128
KINDS = {"func_tests", "stdout"}

KIND_NUM = {"func_tests": 0, "stdout": 1}


class TaskError(Exception):
    pass


def holyc_str(text: str) -> str:
    """Escape a Python string for a HolyC string literal.

    Written with chr() rather than escape sequences so that generating this
    file from another script does not turn into a double-escaping puzzle.
    """
    bs = chr(92)
    esc = {
        bs:       bs + bs,
        chr(34):  bs + chr(34),
        chr(10):  bs + "n",
        chr(9):   bs + "t",
        "$":      "$$",
    }
    return "".join(esc.get(ch, ch) for ch in text)


def load_tasks() -> list[dict]:
    tasks = []
    for path in sorted(glob.glob(os.path.join(TASK_DIR, "*.json"))):
        with open(path, encoding="utf-8") as fh:
            t = json.load(fh)
        validate(t, os.path.basename(path))
        tasks.append(t)
    return tasks


def validate(t: dict, where: str) -> None:
    def need(cond, msg):
        if not cond:
            raise TaskError(f"{where}: {msg}")

    need(t.get("id"), "no id")
    need(len(t["id"]) < ID_MAX, f"id longer than {ID_MAX - 1} chars")
    need("check" in t, "no check block")
    chk = t["check"]
    need(chk.get("kind") in KINDS,
         f"check.kind {chk.get('kind')!r} is not generated yet - have {sorted(KINDS)}")
    need(t.get("start_file"), "start_file missing")
    need(len(t["start_file"]) < PATH_MAX, f"start_file longer than {PATH_MAX - 1}")

    if chk["kind"] == "func_tests":
        need(chk.get("function"), "check.function missing")
        need(len(chk["function"]) < NAME_MAX, f"function name longer than {NAME_MAX - 1}")
        cases = chk.get("cases") or []
        need(cases, "no test cases")
        need(len(cases) <= MAX_CASES, f"more than {MAX_CASES} cases")
        for c in cases:
            need(isinstance(c.get("in"), list) and len(c["in"]) == 1,
                 "each case needs exactly one input - only single-argument functions "
                 "are generated so far")
            need(isinstance(c["in"][0], int) and isinstance(c.get("out"), int),
                 "case inputs and outputs must be integers")
    else:  # stdout
        need(chk.get("expect"), "check.expect missing - say what the run must print")
        need(len(chk["expect"]) < EXPECT_MAX,
             f"check.expect longer than {EXPECT_MAX - 1} chars")
        need(chk.get("match", "contains") == "contains",
             "only match:contains is generated - an exact match would tie the task "
             "to incidental whitespace")
    # The spec requires every task to carry a negative test and three hints.
    need(chk.get("negative"), "check.negative missing - a task must say how an "
                              "empty template is rejected")
    for lang in ("en", "ru"):
        hints = (t.get("hints") or {}).get(lang) or []
        need(len(hints) == 3, f"hints.{lang} must have exactly 3 entries, got {len(hints)}")
    need(t.get("achievement"), "achievement missing")


def render(tasks: list[dict]) -> str:
    L = []
    a = L.append
    # Line comments, not a /* */ block. HolyC nests block comments, so a glob
    # like data/tasks/<star>.json inside one opens a nested comment, the closing
    # */ only balances that, and the whole rest of the file is swallowed with no
    # diagnostic at all. tools/lint_holyc.py checks for it; not writing block
    # comments from a generator avoids it entirely.
    a("// /Game/Tasks.HC - generated, do not edit.")
    a("//")
    a("// Source:     data/tasks (the json files)")
    a("// Regenerate: python tools/gen_tasks.py")
    a("//")
    a("// The JSON is what the host and CI read. This is the same facts in a form")
    a("// the guest can compile, because TempleOS has no JSON parser and does not")
    a("// need one to hold a handful of integers.")
    a("")
    a('#help_index "Game/Tasks"')
    a("")
    a(f"#define TASK_ID_MAX\t{ID_MAX}")
    a(f"#define TASK_NAME_MAX\t{NAME_MAX}")
    a(f"#define TASK_PATH_MAX\t{PATH_MAX}")
    a(f"#define TASK_MAX_CASES\t{MAX_CASES}")
    a(f"#define TASK_EXPECT_MAX\t{EXPECT_MAX}")
    a(f"#define TASK_CNT\t{len(tasks)}")
    a("")
    a("#define TASKK_FUNC_TESTS\t0")
    a("#define TASKK_STDOUT\t\t1")
    a("")
    a("class CTaskCase")
    a("{//Named arg/want rather than in/out. `in` and `out` as member names wedge")
    a(" //the compiler outright - no diagnostic, the terminal simply stops running")
    a(" //what you type. They are x86 instruction mnemonics, and the OS sources")
    a(" //never name a member `in` or `out` either.")
    a("  I64\targ,")
    a("\twant;")
    a("};")
    a("")
    a("class CTaskDef")
    a("{")
    a("  U8\tid[TASK_ID_MAX],")
    a("\tfun[TASK_NAME_MAX],")
    a("\tstart_file[TASK_PATH_MAX],")
    a("\texpect[TASK_EXPECT_MAX];")
    a("  I64\tkind,")
    a("\tcase_cnt;")
    a("  CTaskCase cases[TASK_MAX_CASES];")
    a("};")
    a("")
    a("CTaskDef task_defs[TASK_CNT];")
    a("")
    a("U0 TasksInit()")
    a("{//Filled in by code rather than by an initialiser list: HolyC has no")
    a(" //designated initialisers, and a table written out longhand is easier to")
    a(" //diff when a task changes.")
    a("  CTaskDef *t;")
    for i, t in enumerate(tasks):
        chk = t["check"]
        kind = chk["kind"]
        a("")
        a(f"  //{t['id']} - chapter {t.get('chapter')}, "
          f"{t.get('title', {}).get('en', '')}  [{kind}]")
        a(f"  t=&task_defs[{i}];")
        a("  MemSet(t,0,sizeof(CTaskDef));")
        a(f'  StrCpy(t->id,"{t["id"]}");')
        a(f'  StrCpy(t->start_file,"{t["start_file"]}");')
        a(f"  t->kind={KIND_NUM[kind]};")
        if kind == "func_tests":
            cases = chk["cases"]
            a(f'  StrCpy(t->fun,"{chk["function"]}");')
            a(f"  t->case_cnt={len(cases)};")
            for j, c in enumerate(cases):
                a(f"  t->cases[{j}].arg={c['in'][0]};  t->cases[{j}].want={c['out']};")
        else:
            a(f'  StrCpy(t->expect,"{holyc_str(chk["expect"])}");')
            a("  t->case_cnt=1;")
    a("}")
    a("")
    return "\n".join(L)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if the generated file is stale")
    args = ap.parse_args()

    try:
        tasks = load_tasks()
    except TaskError as exc:
        print(f"invalid task: {exc}", file=sys.stderr)
        return 2
    if not tasks:
        print(f"no task json under {TASK_DIR}", file=sys.stderr)
        return 2

    text = render(tasks)

    if args.check:
        current = ""
        if os.path.isfile(OUT):
            with open(OUT, encoding="utf-8") as fh:
                current = fh.read()
        if current != text:
            print("guest/Game/Tasks.HC is stale - run python tools/gen_tasks.py",
                  file=sys.stderr)
            return 1
        print(f"up to date: {len(tasks)} task(s)")
        return 0

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print(f"wrote {os.path.relpath(OUT, ROOT)}: {len(tasks)} task(s)")
    for t in tasks:
        chk = t["check"]
        if chk["kind"] == "func_tests":
            what = f"{chk['function']}  {len(chk['cases'])} case(s)"
        else:
            what = f"prints {chk['expect']!r}"
        print(f"  {t['id']:<16} {chk['kind']:<11} {what}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
