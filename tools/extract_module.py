#!/usr/bin/env python3
"""Extract functions from root.zig into a new module file.

Usage: python3 tools/extract_module.py <module_name> <fn1> <fn2> ...

Creates src/transpile/<module_name>.zig with the extracted functions,
removes them from src/transpile/root.zig, and adds const aliases.
"""
import re
import sys

ROOT = 'src/transpile/root.zig'

def find_function_range(lines, fn_name):
    """Find the line range (start, end) of a top-level function definition."""
    for i, line in enumerate(lines):
        if re.match(rf'^fn {fn_name}\(', line) or re.match(rf'^const {fn_name} = struct \{{', line) or re.match(rf'^const {fn_name} = enum \{{', line):
            depth = 0
            found_open = False
            for j in range(i, len(lines)):
                for ch in lines[j]:
                    if ch == '{': depth += 1; found_open = True
                    elif ch == '}': depth -= 1
                if found_open and depth == 0:
                    return (i, j)
            break
    return None

def main():
    module_name = sys.argv[1]
    fn_names = sys.argv[2:]

    with open(ROOT, 'r') as f:
        lines = f.read().split('\n')

    # Find all function ranges
    ranges = {}
    not_found = []
    for fn_name in fn_names:
        r = find_function_range(lines, fn_name)
        if r:
            ranges[fn_name] = r
        else:
            not_found.append(fn_name)

    if not_found:
        print(f"WARNING: Not found: {not_found}")

    # Extract function bodies
    extracted_bodies = []
    for fn_name in fn_names:
        if fn_name in ranges:
            start, end = ranges[fn_name]
            body = '\n'.join(lines[start:end+1])
            # Make functions pub
            body = re.sub(r'^fn ', 'pub fn ', body)
            body = re.sub(r'^const ', 'pub const ', body)
            extracted_bodies.append(body)
            print(f"  Extracted {fn_name}: lines {start+1}-{end+1} ({end-start+1} lines)")

    # Write extracted bodies (just the function bodies, user adds header manually)
    output_path = f'src/transpile/{module_name}_extracted.zig'
    with open(output_path, 'w') as f:
        f.write('\n\n'.join(extracted_bodies))
        f.write('\n')

    # Remove from root.zig
    remove_set = set()
    for fn_name, (start, end) in ranges.items():
        for k in range(start, end + 1):
            remove_set.add(k)

    filtered = [lines[i] for i in range(len(lines)) if i not in remove_set]

    # Generate alias lines
    alias_lines = []
    for fn_name in fn_names:
        if fn_name in ranges:
            # Check if it was a struct/enum const
            start = ranges[fn_name][0]
            if lines[start].startswith('const '):
                alias_lines.append(f'const {fn_name} = {module_name}.{fn_name};')
            else:
                alias_lines.append(f'const {fn_name} = {module_name}.{fn_name};')

    with open(ROOT, 'w') as f:
        f.write('\n'.join(filtered))

    print(f"\nRemoved {len(remove_set)} lines from root.zig")
    print(f"Extracted bodies written to: {output_path}")
    print(f"\nAdd to root.zig imports:")
    print(f'  const {module_name} = @import("{module_name}.zig");')
    print(f"\nAdd these aliases:")
    for a in alias_lines:
        print(f'  {a}')

if __name__ == '__main__':
    main()
