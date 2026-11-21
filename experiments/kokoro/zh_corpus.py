"""Lines to compare the front ends on, from books on this machine: every
book in <dir>, <n> paragraphs each from evenly spread places, plus a few
made-up lines for numbers and odd cases. Stays local (the books are the
reader's). usage: zh_corpus.py <dir> <n> <out file>"""
import os
import random
import sys

src, n, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
EXTRA = [
    '2023年5月1日，他花了3.5-4.5公斤的肉钱，大约1/3，涨了-12.5%，气温30℃。',
    '第3章 一百零五个人在1000010米外，0.5小时后3.14159。',
    '１２３个人说：“不不不，一一来，看一看，走一走。”',
    '他想了想，觉得这个小伙儿真不错，女儿在胡同儿里玩儿。',
    'Hello，我是AI助手，iPhone 15 Pro很好用。',
    '嗯，嗯嗯。啊？哦！呃……',
    '老老实实、干干净净、你好你好、展览馆、跑马场、纸老虎。',
    '1,000元；12:30；100000000000000000；007',
    '〇一二三',
]
books = sorted(f for f in os.listdir(src) if f.lower().endswith('.txt'))
rnd = random.Random(7)
lines = list(EXTRA)
for b in books:
    raw = open(os.path.join(src, b), 'rb').read()
    for enc in ('utf-8', 'gb18030', 'utf-16'):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        continue
    paras = [p.strip() for p in text.replace('\r', '').split('\n')]
    paras = [p for p in paras if 4 <= len(p) <= 300]
    if not paras:
        continue
    for p in rnd.sample(paras, min(n, len(paras))):
        lines.append(p.replace(' ', ' ').replace(' ', ' '))
with open(dst, 'w', encoding='utf-8', newline='\n') as out:
    out.write('\n'.join(lines) + '\n')
print(len(books), 'books', len(lines), 'lines')
