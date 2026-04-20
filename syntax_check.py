import sys
import re

def check_blocks(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # Simple check for basic parens/brackets
    stack = []
    pairs = {'(': ')', '[': ']', '{': '}'}
    line_num = 1

    for char in content:
        if char == '\n':
            line_num += 1
        elif char in pairs.keys():
            stack.append((char, line_num))
        elif char in pairs.values():
            if not stack:
                print(f"Error in {filepath}: Unmatched closing {char} on line {line_num}")
                return False
            top, _ = stack.pop()
            if pairs[top] != char:
                print(f"Error in {filepath}: Mismatched {top} and {char} on line {line_num}")
                return False

    if stack:
        char, l_num = stack.pop()
        print(f"Error in {filepath}: Unclosed {char} starting at line {l_num}")
        return False

    print(f"{filepath} passed bracket checks.")
    return True

files = [
    "addons/team_create/ui.gd",
    "addons/team_create/network.gd",
    "addons/team_create/scene_sync.gd",
    "addons/team_create/file_sync.gd",
]

all_passed = True
for f in files:
    if not check_blocks(f):
        all_passed = False

if not all_passed:
    sys.exit(1)
