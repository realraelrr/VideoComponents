#!/usr/bin/env python3
"""Compare an xcresult with Xcode's pre-run flat JSON enumeration, without silent skips."""

import argparse
from collections import Counter
import copy
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import unquote, urlparse


def canonical(identifier):
    identifier = identifier.removesuffix("()")
    if len(identifier.split("/")) != 3 or any(not part for part in identifier.split("/")):
        raise ValueError(f"expected Target/Class/method selector: {identifier!r}")
    return identifier


def inventory(enumeration, excluded=(), included=None):
    if enumeration.get("errors") != []:
        raise ValueError(f"Xcode enumeration errors: {enumeration.get('errors')!r}")
    plans = enumeration.get("values", [])
    if len(plans) != 1:
        raise ValueError("expected exactly one test plan in flat Xcode enumeration")
    plan = plans[0]
    enabled = [canonical(test["identifier"]) for test in plan["enabledTests"]]
    disabled = [canonical(test["identifier"]) for test in plan["disabledTests"]]
    all_tests = enabled + disabled
    if not all_tests or len(all_tests) != len(set(all_tests)):
        raise ValueError("Xcode enumeration is empty or has duplicate selectors")
    all_tests = set(all_tests)
    excluded = set(excluded)
    if excluded - all_tests:
        raise ValueError(f"excluded selectors absent from Xcode enumeration: {sorted(excluded - all_tests)}")
    if included is not None:
        included = set(included)
        if included - all_tests:
            raise ValueError(f"selected selectors absent from Xcode enumeration: {sorted(included - all_tests)}")
        expected = included - excluded
    else:
        expected = all_tests - excluded
    if set(disabled) & expected:
        raise ValueError(f"required tests disabled in Xcode: {sorted(set(disabled) & expected)}")
    if not expected:
        raise ValueError("selection requires zero tests")
    return all_tests, expected


def test_cases(nodes):
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            path = unquote(urlparse(node["nodeIdentifierURL"]).path)
            yield canonical("/".join(path.split("/")[-3:])), node
        if node.get("nodeType") == "Test Case Run" and node.get("result") != "Passed":
            raise ValueError(f"non-passing test attempt: {node.get('name')}: {node.get('result')}")
        yield from test_cases(node.get("children", []))


def verify(summary, tree, expected):
    cases = list(test_cases(tree["testNodes"]))
    counts = Counter(selector for selector, _ in cases)
    if counts != Counter(expected):
        missing = sorted(set(expected) - counts.keys())
        unexpected = sorted(counts.keys() - set(expected))
        duplicates = sorted(key for key, count in counts.items() if count != 1)
        raise ValueError(f"test selector set differs: missing={missing}; unexpected={unexpected}; duplicates={duplicates}")
    for selector, node in cases:
        if node.get("result") != "Passed":
            raise ValueError(f"test did not pass: {selector}: {node.get('result')}")
    for field, required in {"result": "Passed", "totalTestCount": len(expected),
                            "passedTests": len(expected), "failedTests": 0,
                            "skippedTests": 0, "expectedFailures": 0}.items():
        if summary.get(field) != required:
            raise ValueError(f"{field}={summary.get(field)!r}, expected {required!r}")


def read_selectors(path):
    values = [canonical(line.strip()) for line in path.read_text().splitlines()
              if line.strip() and not line.lstrip().startswith("#")]
    if len(values) != len(set(values)):
        raise ValueError(f"duplicate selector in {path}")
    return values


def self_test():
    a, b = "FixtureTests/Example/testA", "FixtureTests/Example/testExtension"
    enumeration = {"errors": [], "values": [{"enabledTests": [
        {"identifier": a + "()"}, {"identifier": b + "()"}], "disabledTests": []}]}
    summary = {"result": "Passed", "totalTestCount": 2, "passedTests": 2,
               "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
    tree = {"testNodes": [{"nodeType": "Test Case", "result": "Passed",
                          "nodeIdentifierURL": "test://com.apple.xcode/Fixture/" + selector}
                         for selector in (a, b)]}
    _, expected = inventory(enumeration)
    verify(summary, tree, expected)
    _, selected = inventory(enumeration, excluded=[b])
    one = {**summary, "totalTestCount": 1, "passedTests": 1}
    verify(one, {"testNodes": tree["testNodes"][:1]}, selected)
    assert inventory(enumeration, included=[b])[1] == {b}
    disabled = copy.deepcopy(enumeration)
    disabled["values"][0]["disabledTests"] = [disabled["values"][0]["enabledTests"].pop()]
    assert inventory(disabled, excluded=[b])[1] == {a}
    assert inventory(disabled, included=[a])[1] == {a}
    skipped = copy.deepcopy(tree)
    skipped["testNodes"][1]["result"] = "Skipped"
    retry = copy.deepcopy(tree)
    retry["testNodes"][0]["children"] = [{"nodeType": "Test Case Run", "result": "Failed"}]
    wrong_target = copy.deepcopy(tree)
    wrong_target["testNodes"][0]["nodeIdentifierURL"] = "test://com.apple.xcode/Fixture/OtherTests/Example/testA"
    invalid = [
        lambda: verify(summary, wrong_target, expected),
        lambda: verify(one, {"testNodes": tree["testNodes"][:1]}, expected),
        lambda: verify(summary, tree, selected),
        lambda: verify(summary, skipped, expected),
        lambda: verify(summary, retry, expected),
        lambda: verify({**summary, "skippedTests": 1}, tree, expected),
        lambda: verify({**summary, "totalTestCount": 0}, tree, expected),
        lambda: verify(summary, {"testNodes": tree["testNodes"] * 2}, expected),
        lambda: inventory(enumeration, excluded=["OtherTests/Example/testMissing"]),
        lambda: inventory(enumeration, included=["OtherTests/Example/testMissing"]),
        lambda: inventory(disabled),
        lambda: inventory({**enumeration, "errors": ["discovery failed"]}),
        lambda: inventory({"errors": [], "values": []}),
    ]
    for check in invalid:
        try:
            check()
        except ValueError:
            continue
        raise AssertionError("invalid inventory/result accepted")
    print(f"xcresult inventory self-test passed: 5 positive, {len(invalid)} negative checks")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", nargs="?", type=Path)
    parser.add_argument("--enumeration", type=Path)
    parser.add_argument("--exclude", type=Path, help="predeclared exact selectors, one per line; # comments allowed")
    parser.add_argument("--include", type=Path, help="explicit focused selection, checked against enumeration")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.result is None or args.enumeration is None:
        parser.error("an xcresult path and --enumeration from the same build/selection are required")
    excluded = read_selectors(args.exclude) if args.exclude else []
    included = read_selectors(args.include) if args.include else None
    all_tests, expected = inventory(json.loads(args.enumeration.read_text()), excluded, included)
    print(f"inventory: enumerated={len(all_tests)} excluded={len(excluded)} required={len(expected)}", flush=True)
    if args.exclude:
        print("Predeclared exclusions (not runtime skips):\n" + args.exclude.read_text(), flush=True)
    def read_report(kind):
        return json.loads(subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", kind,
            "--path", str(args.result), "--compact"], text=True))
    summary, tree = read_report("summary"), read_report("tests")
    print(f"actual: total={summary.get('totalTestCount')} passed={summary.get('passedTests')} "
          f"failed={summary.get('failedTests')} skipped={summary.get('skippedTests')}", flush=True)
    verify(summary, tree, expected)
    print(f"verified exact selector set: {len(expected)} passed, zero skipped: {args.result}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit("error: " + str(error))
