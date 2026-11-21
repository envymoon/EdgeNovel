"""The Chinese front end's data, exported from the original (misaki 1.1 zh =
jieba + pypinyin + pypinyin-dict, all MIT) after its own set-up, for the Rust
port in core/src/zh_g2p.rs.

usage: export_zh.py <out.bin>

Format: b'KZH1', then sections: 4-byte tag, u32 byte length, payload.
Strings are u16 length + UTF-8. Sorted lists are sorted by UTF-8 bytes.
"""
import struct
import sys

from misaki.zh_frontend import ZHFrontend  # noqa: loads large_pinyin and misaki's overrides

ZHFrontend()

import jieba
import jieba.posseg as pseg
from jieba.finalseg import prob_emit as fs_emit, prob_start as fs_start, prob_trans as fs_trans
from jieba.posseg import char_state_tab, prob_emit as ps_emit, prob_start as ps_start, prob_trans as ps_trans
from pypinyin import Style, lazy_pinyin
from pypinyin.constants import PHRASES_DICT, PINYIN_DICT, RE_HANS

out = open(sys.argv[1], 'wb')
out.write(b'KZH1')


def s(x):
    b = x.encode('utf-8')
    return struct.pack('<H', len(b)) + b


def section(tag, payload):
    out.write(tag + struct.pack('<I', len(payload)) + payload)


def sorted_strs(words):
    return sorted(words, key=lambda w: w.encode('utf-8'))


# -- jieba's dictionary, as jieba itself reads it: later lines win, the total
# counts every line.
jieba.dt.check_initialized()
entries = {}
total = 0
for line in open(jieba.dt.get_dict_file().name if hasattr(jieba.dt.get_dict_file(), 'name') else jieba.get_dict_file(), 'rb'):
    parts = line.decode('utf-8').strip().split(' ')
    if not parts[0]:
        continue
    word, freq = parts[0], int(parts[1])
    tag = parts[2] if len(parts) > 2 else None
    total += freq
    entries[word] = (freq, tag if tag is not None else entries.get(word, (0, None))[1])
assert total == jieba.dt.total, (total, jieba.dt.total)
for w, (f, _) in entries.items():
    assert jieba.dt.FREQ[w] == f, w
tag_names = sorted({t for _, t in entries.values() if t})
tag_index = {t: i for i, t in enumerate(tag_names)}
payload = struct.pack('<Q', total) + struct.pack('<I', len(tag_names)) + b''.join(s(t) for t in tag_names)
words = sorted_strs(entries)
payload += struct.pack('<I', len(words))
for w in words:
    f, t = entries[w]
    payload += s(w) + struct.pack('<IH', f, tag_index[t] if t else 0xFFFF)
section(b'JDCT', payload)
# posseg's word tags come from the same file.
assert all(pseg.dt.word_tag_tab.get(w) == t for w, (f, t) in entries.items() if t), 'tag table differs'

# -- jieba's HMM for unknown words (BMES).
payload = b''
for st in 'BMES':
    payload += struct.pack('<d', fs_start.P[st])
for a in 'BMES':
    for b in 'BMES':
        payload += struct.pack('<d', fs_trans.P[a].get(b, -3.14e100))
for st in 'BMES':
    em = fs_emit.P[st]
    payload += struct.pack('<I', len(em))
    for ch in sorted(em):
        payload += struct.pack('<Id', ord(ch), em[ch])
section(b'FSEG', payload)

# -- posseg's HMM: states sorted as Python sorts the tuples.
states = sorted(set(ps_start.P) | set(ps_trans.P) | {y for d in ps_trans.P.values() for y in d} | set(ps_emit.P))
index = {st: i for i, st in enumerate(states)}
payload = struct.pack('<I', len(states))
for st in states:
    payload += s(st[0]) + s(st[1]) + struct.pack('<d', ps_start.P.get(st, float('-inf')))
for st in states:
    tr = ps_trans.P.get(st, {})
    payload += struct.pack('<I', len(tr))
    for y in sorted(tr):
        payload += struct.pack('<Hd', index[y], tr[y])
for st in states:
    em = ps_emit.P.get(st, {})
    payload += struct.pack('<I', len(em))
    for ch in sorted(em):
        payload += struct.pack('<Id', ord(ch), em[ch])
payload += struct.pack('<I', len(char_state_tab.P))
for ch in sorted(char_state_tab.P):
    sts = char_state_tab.P[ch]
    payload += struct.pack('<IH', ord(ch), len(sts)) + b''.join(struct.pack('<H', index[x]) for x in sts)
section(b'PSEG', payload)

# -- pinyin: every reading as misaki asks for it (initials, and finals with
# the tone as a digit, 5 for neutral), for single characters and phrases.
syllables = {}


def syl(initial, final):
    return syllables.setdefault((initial, final), len(syllables))


def readings(text):
    ini = lazy_pinyin(text, neutral_tone_with_five=True, style=Style.INITIALS)
    fin = lazy_pinyin(text, neutral_tone_with_five=True, style=Style.FINALS_TONE3)
    return ini, fin


# Every character pypinyin calls Chinese, with what it gives for it alone
# (a character it has no reading for comes back as itself).
hans = [cp for cp in range(0x110000) if RE_HANS.match(chr(cp))]
chars = {}
for cp in hans:
    ini, fin = readings(chr(cp))
    assert len(ini) == 1 and len(fin) == 1, cp
    chars[cp] = syl(ini[0], fin[0])
# Phrases whose readings do not match their length are kept for the
# segmenter but have no readings (pypinyin would fail on them).
phrases = {}
odd = 0
for p in PHRASES_DICT:
    ini, fin = readings(p)
    if len(ini) != len(p) or len(fin) != len(p):
        phrases[p] = []
        odd += 1
        continue
    phrases[p] = [syl(a, b) for a, b in zip(ini, fin)]
print(f'{len(chars)} characters, {len(phrases)} phrases ({odd} odd), {len(syllables)} syllables')
payload = struct.pack('<I', len(syllables))
for (a, b), i in sorted(syllables.items(), key=lambda kv: kv[1]):
    payload += s(a) + s(b)
payload += struct.pack('<I', len(chars))
for cp, i in sorted(chars.items()):
    payload += struct.pack('<IH', cp, i)
names = sorted_strs(phrases)
payload += struct.pack('<I', len(names))
for p in names:
    payload += s(p) + struct.pack('<B', len(phrases[p])) + b''.join(struct.pack('<H', i) for i in phrases[p])
section(b'PINY', payload)

# -- which characters pypinyin treats as Chinese (its RE_HANS), and which
# Python calls numeric: the rules ask both.
import unicodedata
digits = [cp for cp in range(0x110000) if unicodedata.category(chr(cp)) == 'Nd']
numeric = [cp for cp in range(0x110000) if chr(cp).isnumeric()]
spaces = [cp for cp in range(0x110000) if chr(cp).isspace()]


def ranges(cps):
    r = []
    for cp in cps:
        if r and r[-1][1] == cp - 1:
            r[-1][1] = cp
        else:
            r.append([cp, cp])
    return struct.pack('<I', len(r)) + b''.join(struct.pack('<II', a, b) for a, b in r)


section(b'HANS', ranges(hans))
section(b'NUMC', ranges(numeric))
section(b'SPAC', ranges(spaces))
section(b'DIGT', ranges(digits))
out.close()
