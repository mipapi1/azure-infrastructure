#!/usr/bin/env python3
"""Fill the parameter tables in READMEs from the Bicep templates.

Every README.md that contains

    <!-- BEGIN_PARAMS -->
    <!-- END_PARAMS -->

gets a table of the parameters of the main.bicep next to it, built from the
compiled template (bicep build --stdout): name, type, required, default and
the @description text. Run it with `make docs`; `--check` fails when a table
is out of date, for CI.
"""
import json
import pathlib
import subprocess
import sys

BEGIN = "<!-- BEGIN_PARAMS -->"
END = "<!-- END_PARAMS -->"
SKIP_DIRS = {".git", ".work", "out", "node_modules"}
MAX_DEFAULT = 40


def compile_template(path: pathlib.Path) -> dict:
    out = subprocess.run(
        ["bicep", "build", str(path), "--stdout"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)


def type_name(param: dict) -> str:
    ref = param.get("$ref")
    if ref:
        return ref.rsplit("/", 1)[-1]
    if "allowedValues" in param:
        return " \\| ".join(f"`{v}`" for v in param["allowedValues"])
    items = param.get("items")
    if param.get("type") == "array" and isinstance(items, dict):
        inner = items.get("$ref", "").rsplit("/", 1)[-1] or items.get("type", "")
        return f"{inner}[]" if inner else "array"
    t = param.get("type", "")
    return {"securestring": "string (secure)", "secureObject": "object (secure)"}.get(t, t)


def default_text(param: dict) -> str:
    if "defaultValue" not in param:
        return ""
    value = param["defaultValue"]
    if isinstance(value, str) and value.startswith("[") and value.endswith("]"):
        return "computed"
    text = json.dumps(value, separators=(",", ":"))
    if len(text) > MAX_DEFAULT:
        return "see template"
    return f"`{text}`"


def describe(param: dict) -> str:
    text = param.get("metadata", {}).get("description", "")
    for prefix in ("Required. ", "Optional. ", "Conditional. "):
        if text.startswith(prefix):
            text = text[len(prefix):]
    return text.replace("|", "\\|").replace("\n", " ")


def table(template: dict) -> str:
    rows = [
        "| Parameter | Type | Required | Default | Description |",
        "|---|---|---|---|---|",
    ]
    for name, param in template.get("parameters", {}).items():
        required = "defaultValue" not in param and not param.get("nullable", False)
        rows.append(
            f"| `{name}` | {type_name(param)} | {'yes' if required else 'no'} "
            f"| {default_text(param)} | {describe(param)} |"
        )
    outputs = template.get("outputs", {})
    if outputs:
        rows += ["", "| Output | Type | Description |", "|---|---|---|"]
        for name, output in outputs.items():
            rows.append(f"| `{name}` | {type_name(output)} | {describe(output)} |")
    return "\n".join(rows)


def readmes(root: pathlib.Path):
    for readme in sorted(root.rglob("README.md")):
        if SKIP_DIRS.intersection(readme.relative_to(root).parts):
            continue
        text = readme.read_text()
        if BEGIN in text and END in text and (readme.parent / "main.bicep").exists():
            yield readme, text


def main() -> int:
    check = "--check" in sys.argv
    root = pathlib.Path(__file__).resolve().parent.parent
    stale = []
    for readme, text in readmes(root):
        generated = table(compile_template(readme.parent / "main.bicep"))
        head, rest = text.split(BEGIN, 1)
        _, tail = rest.split(END, 1)
        updated = f"{head}{BEGIN}\n{generated}\n{END}{tail}"
        if updated != text:
            stale.append(readme.relative_to(root))
            if not check:
                readme.write_text(updated)
    for path in stale:
        print(f"{'stale' if check else 'updated'}: {path}")
    return 1 if check and stale else 0


if __name__ == "__main__":
    sys.exit(main())
