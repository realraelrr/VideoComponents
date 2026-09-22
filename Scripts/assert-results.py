#!/usr/bin/env python3
"""Require successful, nonempty suites and named cases in an xcresult bundle."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def canonical(identifier):
    return identifier.removesuffix("()")


def test_cases(nodes, ancestors=()):
    for node in nodes:
        suites = ancestors
        if node.get("nodeType") == "Test Suite":
            suites += (node["name"].rsplit(".", 1)[-1],)
        if node.get("nodeType") == "Test Case":
            identifiers = {canonical(node.get("nodeIdentifier", ""))}
            name = canonical(node["name"])
            identifiers.update(f"{suite}/{name}" for suite in suites)
            # XCTest can prefix a class identifier with its module name.
            identifiers.update(value.rsplit(".", 1)[-1] for value in tuple(identifiers))
            yield node, identifiers, suites
        yield from test_cases(node.get("children", ()), suites)


def verify(summary, tree, suites, required_tests):
    if summary.get("result") != "Passed":
        raise ValueError(f"test result is {summary.get('result')!r}")
    total = summary.get("totalTestCount", 0)
    if not isinstance(total, int) or total <= 0:
        raise ValueError("zero tests executed")
    for field in ("failedTests", "skippedTests", "expectedFailures"):
        if summary.get(field) != 0:
            raise ValueError(f"{field} must be zero, got {summary.get(field)!r}")
    if summary.get("passedTests") != total:
        raise ValueError("not every executed test passed")

    cases = list(test_cases(tree.get("testNodes", ())))
    counts = {}
    for suite in suites:
        matches = [
            node for node, identifiers, ancestors in cases
            if suite in ancestors or any(value.startswith(f"{suite}/") for value in identifiers)
        ]
        if not matches:
            raise ValueError(f"required suite executed zero tests: {suite}")
        if any(node.get("result") != "Passed" for node in matches):
            raise ValueError(f"required suite contains a non-passing case: {suite}")
        counts[suite] = len(matches)

    for identifier in required_tests:
        matches = [node for node, identifiers, _ in cases if canonical(identifier) in identifiers]
        if not matches or any(node.get("result") != "Passed" for node in matches):
            raise ValueError(f"required test did not pass: {identifier}")
    return counts


def self_test():
    summary = {
        "result": "Passed", "totalTestCount": 1, "passedTests": 1,
        "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
    }
    tree = {"testNodes": [{
        "nodeType": "Test Suite", "name": "FixtureTests", "children": [{
            "nodeType": "Test Case", "name": "testRequired()",
            "nodeIdentifier": "FixtureTests/testRequired()", "result": "Passed",
        }],
    }]}
    assert verify(summary, tree, ["FixtureTests"], ["FixtureTests/testRequired"]) == {"FixtureTests": 1}
    invalid = [
        ({**summary, "totalTestCount": 0, "passedTests": 0}, tree, ["FixtureTests"], []),
        (summary, tree, ["AbsentTests"], []),
        (summary, tree, ["FixtureTests"], ["FixtureTests/testAbsent"]),
        ({**summary, "skippedTests": 1}, tree, ["FixtureTests"], []),
        ({**summary, "failedTests": 1}, tree, ["FixtureTests"], []),
        (summary, {"testNodes": [{
            "nodeType": "Test Case", "name": "testRequired()",
            "nodeIdentifier": "FixtureTests/testRequired()", "result": "Skipped",
        }]}, ["FixtureTests"], ["FixtureTests/testRequired"]),
    ]
    for arguments in invalid:
        try:
            verify(*arguments)
        except ValueError:
            continue
        raise AssertionError("a missing, skipped, failed, or empty result was accepted")
    print("xcresult assertion self-test passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", nargs="?", type=Path)
    parser.add_argument("--suite", action="append", default=[])
    parser.add_argument("--test", action="append", default=[])
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--expectations", type=Path)
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
        return
    if arguments.expectations:
        expected = json.loads(arguments.expectations.read_text())
        arguments.suite.extend(expected["suites"])
        arguments.test.extend(expected["tests"])
        arguments.suite = sorted(set(arguments.suite))
        arguments.test = sorted(set(arguments.test))
    if arguments.result is None or not arguments.suite:
        parser.error("an xcresult path and at least one --suite are required")

    def read_report(kind):
        output = subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", kind,
            "--path", str(arguments.result), "--compact",
        ], text=True)
        return json.loads(output)

    counts = verify(read_report("summary"), read_report("tests"), arguments.suite, arguments.test)
    for suite, count in counts.items():
        print(f"verified {suite}: {count} passing tests")
    print(f"verified {len(arguments.test)} required test IDs in {arguments.result}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
