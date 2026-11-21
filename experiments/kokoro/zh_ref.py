"""The original's Chinese front end, line by line, to compare with
`zhprobe`: zh_ref.py <text file> <out file> [--seg]"""
import sys

import jieba.posseg as psg
from misaki import zh

src, dst = sys.argv[1:3]
seg = '--seg' in sys.argv
g2p = zh.ZHG2P(version='1.1')
text = open(src, encoding='utf-8').read().split('\n')
if text and text[-1] == '':
    text.pop()
with open(dst, 'w', encoding='utf-8', newline='\n') as out:
    for line in text:
        line = line.rstrip('\r')
        if seg:
            out.write(' '.join(f'{p.word}/{p.flag}' for p in psg.lcut(line)) + '\n')
        else:
            # The original fails on a few lines; those are marked, not compared.
            try:
                out.write(g2p(line)[0] + '\n')
            except Exception as e:
                out.write(f'<<{type(e).__name__}>>\n')
