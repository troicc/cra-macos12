#!/usr/bin/env python3
"""Wrap SwiftUI view bodies (and lazily evaluated view-builder closures) in WithPerceptionTracking.

On macOS 12/13 swift-perception only re-renders a view whose body reads @Perceptible state inside
WithPerceptionTracking; on macOS 14+ the wrapper is a passthrough. Usage: wrap_perception.py <files...>
Prints a summary; edits files in place.
"""
import re
import sys

W = "WithPerceptionTracking"


def skip_string(s, i):
    """i at the opening quote (possibly after #s). Returns index after the literal."""
    hashes = 0
    while s[i] == '#':
        hashes += 1
        i += 1
    multi = s.startswith('"""', i)
    q = '"""' if multi else '"'
    i += len(q)
    close = q + '#' * hashes
    while i < len(s):
        if s.startswith(close, i):
            return i + len(close)
        c = s[i]
        if c == '\\' and s[i + 1:i + 1 + hashes] == '#' * hashes:
            j = i + 1 + hashes
            if j < len(s) and s[j] == '(':
                # interpolation: match parens, strings allowed inside
                depth = 0
                k = j
                while k < len(s):
                    ch = s[k]
                    if ch == '"' or (ch == '#' and s[k:].lstrip('#').startswith('"')):
                        k = skip_string(s, k)
                        continue
                    if ch == '(':
                        depth += 1
                    elif ch == ')':
                        depth -= 1
                        if depth == 0:
                            k += 1
                            break
                    k += 1
                i = k
                continue
            i = j + 1
            continue
        i += 1
    raise ValueError("unterminated string")


def match_brace(s, i):
    """s[i] == '{'. Returns index of matching '}'."""
    depth = 0
    n = len(s)
    while i < n:
        c = s[i]
        if s.startswith('//', i):
            i = s.find('\n', i)
            if i < 0:
                return -1
            continue
        if s.startswith('/*', i):
            d = 0
            while i < n:
                if s.startswith('/*', i):
                    d += 1
                    i += 2
                elif s.startswith('*/', i):
                    d -= 1
                    i += 2
                    if d == 0:
                        break
                else:
                    i += 1
            continue
        if c == '"' or (c == '#' and re.match(r'#+"', s[i:])):
            i = skip_string(s, i)
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def code_mask(s):
    """Positions that are code (not comment/string), as a bytearray of 1/0."""
    m = bytearray(len(s))
    i, n = 0, len(s)
    while i < n:
        if s.startswith('//', i):
            j = s.find('\n', i)
            i = n if j < 0 else j
            continue
        if s.startswith('/*', i):
            j = s.find('*/', i)
            i = n if j < 0 else j + 2
            continue
        if s[i] == '"' or (s[i] == '#' and re.match(r'#+"', s[i:])):
            i = skip_string(s, i)
            continue
        m[i] = 1
        i += 1
    return m


BODY = re.compile(r'(var body: some View|func body\(content: Content\) -> some View|func makeBody\(configuration: Configuration\) -> some View)\s*\{')
LAZY = re.compile(r'(\bForEach\b|\bGeometryReader\b|\.popover\b|\.sheet\b)')
PARAMS = re.compile(r'^\s*(\[[^\]\n]*\]\s*)?(\(?\s*[A-Za-z_][\w]*(\s*:\s*[\w.<>?\[\]]+)?(\s*,\s*[A-Za-z_][\w]*(\s*:\s*[\w.<>?\[\]]+)?)*\s*\)?|_)\s+in\b')


def wrap_at(s, open_i, is_body=False):
    """Wrap the contents of the closure whose '{' is at open_i. Returns new s or None."""
    close_i = match_brace(s, open_i)
    if close_i < 0:
        return None
    inner = s[open_i + 1:close_i]
    head_len = 0
    m = PARAMS.match(inner)
    if m:
        head_len = m.end()
    content = inner[head_len:]
    if content.strip().startswith(W):
        return None
    if not is_body and not m and re.search(r'\$\d', content):
        return None  # the closure's own shorthand args can't cross into the wrapper's closure
    if not content.strip():
        return None
    new_inner = inner[:head_len] + ' ' + W + ' {' + content + '}' + ' '
    return s[:open_i + 1] + new_inner + s[close_i:]


def find_lazy_closure(s, start, mask):
    """For a lazy call starting at `start`, the '{' of its trailing content closure, or -1."""
    i = start
    n = len(s)
    # skip the name
    m = LAZY.match(s, i)
    i = m.end()
    depth = 0
    while i < n:
        c = s[i]
        if not mask[i]:
            i += 1
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth < 0:
                return -1
        elif c == '{' and depth == 0:
            return i
        elif c == '\n' and depth == 0:
            # trailing closure must start on the same line
            return -1
        i += 1
    return -1


def process(path):
    s = open(path, encoding='utf-8').read()
    original = s
    bodies = lazies = 0
    # Bodies first, from the end so indices stay valid.
    mask = code_mask(s)
    hits = [m for m in BODY.finditer(s) if mask[m.start()]]
    for m in reversed(hits):
        r = wrap_at(s, m.end() - 1, is_body=True)
        if r is not None:
            s = r
            bodies += 1
    # Lazy closures, from the end.
    mask = code_mask(s)
    starts = [m.start() for m in LAZY.finditer(s) if mask[m.start()]]
    for st in reversed(starts):
        mask = code_mask(s) if len(mask) != len(s) else mask
        o = find_lazy_closure(s, st, mask)
        if o < 0:
            continue
        r = wrap_at(s, o)
        if r is not None:
            s = r
            lazies += 1
            mask = code_mask(s)
    if s != original:
        if not re.search(r'^import Perception\b', s, re.M):
            s = re.sub(r'^(import SwiftUI\b.*)$', r'\1\nimport Perception', s, count=1, flags=re.M)
            if 'import Perception' not in s:
                s = 'import Perception\n' + s
        open(path, 'w', encoding='utf-8').write(s)
    return bodies, lazies


if __name__ == '__main__':
    tb = tl = files = 0
    for p in sys.argv[1:]:
        b, l = process(p)
        if b or l:
            files += 1
            print(f"{p}: bodies={b} lazy={l}")
        tb += b
        tl += l
    print(f"total files={files} bodies={tb} lazy={tl}")
