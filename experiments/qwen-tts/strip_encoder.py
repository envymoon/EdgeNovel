"""Drops the codec's encoder: every tensor named tok_enc.*. The encoder turns
reference audio into codes and is only used to clone a voice; the named
speakers of the CustomVoice model never need it. Metadata and every other
tensor are copied as they are, so the decoder's output is byte-identical.

usage: python strip_encoder.py qwen-tokenizer-12hz-Q8_0.gguf qwen-tokenizer-12hz-dec-Q8_0.gguf
"""
import struct
import sys

BLOCK = {0: (1, 4), 1: (1, 2), 8: (32, 34), 12: (256, 144), 13: (256, 176), 14: (256, 210), 30: (1, 2),
         24: (1, 1), 25: (1, 2), 26: (1, 4), 27: (1, 8), 28: (1, 8)}
SCALAR = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


class R:
    def __init__(self, f):
        self.f = f

    def rd(self, fmt):
        return struct.unpack("<" + fmt, self.f.read(struct.calcsize("<" + fmt)))[0]

    def rstr(self):
        return self.f.read(self.rd("Q")).decode("utf-8", "surrogateescape")

    def val(self, t):
        if t in SCALAR:
            return self.rd(SCALAR[t])
        if t == 8:
            return self.rstr()
        if t == 9:
            at = self.rd("I"); n = self.rd("Q")
            if at in SCALAR:
                fmt = SCALAR[at]
                data = self.f.read(n * struct.calcsize("<" + fmt))
                return (at, list(struct.unpack(f"<{n}{fmt}", data)))
            return (at, [self.val(at) for _ in range(n)])
        raise ValueError(t)


def load(path):
    f = open(path, "rb")
    r = R(f)
    assert f.read(4) == b"GGUF"
    version = r.rd("I"); nt = r.rd("Q"); nkv = r.rd("Q")
    kv = []
    for _ in range(nkv):
        k = r.rstr(); t = r.rd("I")
        kv.append([k, t, r.val(t)])
    align = next((v for k, t, v in kv if k == "general.alignment"), 32)
    tensors = []
    for _ in range(nt):
        name = r.rstr(); nd = r.rd("I"); dims = [r.rd("Q") for _ in range(nd)]; t = r.rd("I"); off = r.rd("Q")
        n = 1
        for d in dims:
            n *= d
        blk, bs = BLOCK[t]
        tensors.append(dict(name=name, dims=dims, type=t, off=off, size=n // blk * bs))
    data = (f.tell() + align - 1) // align * align
    return dict(path=path, version=version, kv=kv, align=align, tensors=tensors, data=data, f=f)


def read_tensor(g, t):
    g["f"].seek(g["data"] + t["off"])
    return g["f"].read(t["size"])


class W:
    def __init__(self, f):
        self.f = f

    def wr(self, fmt, v):
        self.f.write(struct.pack("<" + fmt, v))

    def wstr(self, s):
        b = s.encode("utf-8", "surrogateescape")
        self.wr("Q", len(b)); self.f.write(b)

    def val(self, t, v):
        if t in SCALAR:
            self.wr(SCALAR[t], v)
        elif t == 8:
            self.wstr(v)
        elif t == 9:
            at, items = v
            self.wr("I", at); self.wr("Q", len(items))
            if at in SCALAR:
                self.f.write(struct.pack(f"<{len(items)}{SCALAR[at]}", *items))
            else:
                for x in items:
                    self.val(at, x)


def save(path, version, kv, align, tensors):
    """tensors: list of (name, dims, type, bytes_or_callable)."""
    with open(path, "wb") as f:
        w = W(f)
        f.write(b"GGUF"); w.wr("I", version); w.wr("Q", len(tensors)); w.wr("Q", len(kv))
        for k, t, v in kv:
            w.wstr(k); w.wr("I", t); w.val(t, v)
        off = 0
        sizes = []
        for name, dims, t, data in tensors:
            n = 1
            for d in dims:
                n *= d
            blk, bs = BLOCK[t]
            size = n // blk * bs
            sizes.append(size)
            w.wstr(name); w.wr("I", len(dims))
            for d in dims:
                w.wr("Q", d)
            w.wr("I", t); w.wr("Q", off)
            off = (off + size + align - 1) // align * align
        f.write(b"\0" * ((-f.tell()) % align))
        for (name, dims, t, data), size in zip(tensors, sizes):
            b = data() if callable(data) else data
            assert len(b) == size, (name, len(b), size)
            f.write(b)
            f.write(b"\0" * ((-f.tell()) % align))


if __name__ == "__main__":
    g = load(sys.argv[1])
    keep = [t for t in g["tensors"] if not t["name"].startswith("tok_enc.")]
    save(sys.argv[2], g["version"], g["kv"], g["align"],
         [(t["name"], t["dims"], t["type"], (lambda t=t: read_tensor(g, t))) for t in keep])
    print("tensors", len(g["tensors"]), "->", len(keep))
