#!/usr/bin/env python3
"""Reject new oversized Swift types and initializers; report existing debt.

This is a structural guard, not a replacement for Swift's parser or code review.
It ignores comments, strings, computed/static properties, and nested function
bodies when counting a type's stored properties.
"""

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "scripts/swift-maintainability-baseline.json"
LIMITS = {"stored_properties": 20, "initializer_parameters": 16, "initializer_assignments": 20}
TOKEN = re.compile(
    r'//[^\n]*|/\*[\s\S]*?\*/|#*"""[\s\S]*?"""#*|#*"(?:\\.|[^"\\])*"#*'
    r"|`[^`]+`|[A-Za-z_][A-Za-z_0-9]*|[^\s]"
)


def measure(source):
    tokens = [(m.group(), m.start(), m.end()) for m in TOKEN.finditer(source)
              if not m.group().startswith(("//", "/*"))]
    pairs, stack, depths = {}, [], []
    for index, (token, _, _) in enumerate(tokens):
        depths.append(len(stack))
        if token in ("{", "(", "["):
            stack.append(index)
        elif token in ("}", ")", "]") and stack:
            opening = stack.pop()
            pairs[opening] = index

    types = []
    for index, (token, start, _) in enumerate(tokens):
        if token not in ("struct", "class", "extension") or index + 1 >= len(tokens):
            continue
        if index and tokens[index - 1][0] in ("import", "."):
            continue
        name = tokens[index + 1][0]
        if name in ("func", "var", "let"):
            continue
        opening = index + 2
        while opening < len(tokens) and tokens[opening][0] not in ("{", "=", ";"):
            opening += 1
        if opening not in pairs or tokens[opening][0] != "{":
            continue
        closing = pairs[opening]
        parents = [entry[0] for entry in types if entry[1] < index < entry[2]]
        qualified = ".".join(parents[-1:] + [name])
        types.append((qualified, opening, closing))

    result = {}
    for name, opening, closing in types:
        fields = set()
        initializers = []
        for index in range(opening + 1, closing):
            token, start, _ = tokens[index]
            if depths[index] != depths[opening] + 1:
                continue
            if token in ("let", "var"):
                line_start = source.rfind("\n", 0, start) + 1
                prefix = source[line_start:start]
                if re.search(r"\b(static|class)\b", prefix):
                    continue
                end = index + 2
                while end < closing:
                    gap = source[tokens[end - 1][2]:tokens[end][1]]
                    if "\n" in gap or tokens[end][0] in ("{", ";", "}"):
                        break
                    end += 1
                header = [t[0] for t in tokens[index + 2:end]]
                observer = end + 1 < closing and tokens[end + 1][0] in ("didSet", "willSet")
                computed = end < closing and tokens[end][0] == "{" and "=" not in header and not observer
                if not computed:
                    fields.add(tokens[index + 1][0])
            elif token == "init":
                parameter_start = index + 1
                if tokens[parameter_start][0] in ("?", "!"):
                    parameter_start += 1
                if parameter_start not in pairs or tokens[parameter_start][0] != "(":
                    continue
                parameter_end = pairs[parameter_start]
                count, angle_depth = 0, 0
                for argument in range(parameter_start + 1, parameter_end):
                    value = tokens[argument][0]
                    if depths[argument] != depths[parameter_start] + 1:
                        continue
                    if value == "<":
                        angle_depth += 1
                    elif value == ">" and angle_depth:
                        angle_depth -= 1
                    elif value == ":" and angle_depth == 0:
                        count += 1
                body = parameter_end + 1
                while body < closing and tokens[body][0] != "{":
                    body += 1
                if body in pairs:
                    initializers.append((count, body, pairs[body]))
        assignments = 0
        for _, body, end in initializers:
            assigned = set()
            for index in range(body + 1, end - 1):
                token = tokens[index][0]
                if token not in fields or tokens[index + 1][0] != "=":
                    continue
                if tokens[index + 2][0] == "=" or tokens[index - 1][0] in ("let", "var"):
                    continue
                assigned.add(token)
            assignments = max(assignments, len(assigned))
        entry = {"stored_properties": len(fields),
                 "initializer_parameters": max((item[0] for item in initializers), default=0),
                 "initializer_assignments": assignments}
        prior = result.get(name, {})
        result[name] = {metric: max(value, prior.get(metric, 0)) for metric, value in entry.items()}
    return result


def inventory():
    result = {}
    for package in ("Engine", "Editor", "GuavaUI"):
        for path in sorted((ROOT / package / "Sources").rglob("*.swift")):
            for name, metrics in measure(path.read_text()).items():
                result[f"{path.relative_to(ROOT).as_posix()}::{name}"] = metrics
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true", help="also list existing oversized declarations")
    args = parser.parse_args()
    baseline = json.loads(BASELINE.read_text())["declarations"]
    violations, debt = [], []
    for identity, metrics in inventory().items():
        for metric, actual in metrics.items():
            limit = LIMITS[metric]
            allowance = baseline.get(identity, {}).get(metric, limit)
            if actual > max(limit, allowance):
                violations.append(f"{identity}: {metric}={actual}, allowed={max(limit, allowance)}")
            elif actual > limit:
                debt.append(f"{identity}: {metric}={actual} (existing debt)")
    if args.report:
        print("\n".join(debt))
    if violations:
        print("\n".join(violations))
        print("Split the declaration by responsibility; do not raise the baseline to silence this check.")
        return 1
    print(f"Swift maintainability check passed; {len(debt)} existing over-limit metrics cannot grow.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
