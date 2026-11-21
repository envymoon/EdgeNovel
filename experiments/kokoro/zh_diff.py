"""How many lines two front ends agree on, and the first that differ:
zh_diff.py <text> <ref out> <port out> [how many to show]"""
import sys

text, a, b = (open(p, encoding='utf-8').read().split('\n') for p in sys.argv[1:4])
show = int(sys.argv[4]) if len(sys.argv) > 4 else 10
n = min(len(a), len(b))
failed = sum(1 for x in a[:n] if x.startswith('<<'))
bad = [i for i in range(n) if a[i] != b[i] and not a[i].startswith('<<')]
print(f'{n - failed - len(bad)} / {n - failed} lines the same ({len(a)} vs {len(b)} lines, {failed} the original fails on)')
for i in bad[:show]:
    print(f'--- {i}: {text[i][:120]}')
    # Where they part.
    k = next((j for j in range(min(len(a[i]), len(b[i]))) if a[i][j] != b[i][j]), min(len(a[i]), len(b[i])))
    print('  ref :', a[i][max(0, k - 30):k + 50])
    print('  port:', b[i][max(0, k - 30):k + 50])
