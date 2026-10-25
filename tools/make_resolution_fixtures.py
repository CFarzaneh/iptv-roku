"""Generate small, offline codec-header fixtures; no provider data is used."""
import json
from pathlib import Path


class Bits:
    def __init__(self): self.bits = ''
    def put(self, value, count): self.bits += f'{value:0{count}b}'
    def ue(self, value):
        code = f'{value + 1:b}'
        self.bits += '0' * (len(code) - 1) + code
    def finish(self):
        self.bits += '1'
        self.bits += '0' * (-len(self.bits) % 8)
        raw = int(self.bits, 2).to_bytes(len(self.bits) // 8, 'big')
        out = bytearray(); zeros = 0
        for byte in raw:
            if zeros >= 2 and byte <= 3: out.append(3); zeros = 0
            out.append(byte)
            zeros = zeros + 1 if byte == 0 else 0
        return bytes(out)


def avc(width, height, high=False, interlaced=False):
    b = Bits(); b.put(100 if high else 66, 8); b.put(0, 8); b.put(40, 8); b.ue(0)
    if high:
        b.ue(1); b.ue(0); b.ue(0); b.put(0, 1); b.put(0, 1)
    b.ue(0); b.ue(0); b.ue(0); b.ue(1); b.put(0, 1)
    frame_factor = 2 if interlaced else 1
    coded_height = ((height + 16 * frame_factor - 1) // (16 * frame_factor)) * 16 * frame_factor
    b.ue(width // 16 - 1); b.ue(coded_height // (16 * frame_factor) - 1)
    b.put(0 if interlaced else 1, 1)
    if interlaced: b.put(0, 1)
    b.put(1, 1); b.put(int(coded_height != height), 1)
    if coded_height != height:
        b.ue(0); b.ue(0); b.ue(0); b.ue((coded_height - height) // (2 * frame_factor))
    return b'\x67' + b.finish()


def hevc(width, height, cropped=False, layers=0):
    b = Bits(); b.put(0, 4); b.put(layers, 3); b.put(1, 1); b.put(0, 96)
    for i in range(layers): b.put(int(i == 0), 1); b.put(1, 1)
    if layers: b.put(0, (8 - layers) * 2)
    for i in range(layers):
        if i == 0: b.put(0, 88)
        b.put(0, 8)
    b.ue(0); b.ue(1)
    b.ue(width + 256 if cropped else width); b.ue(height + 16 if cropped else height)
    b.put(int(cropped), 1)
    if cropped: b.ue(64); b.ue(64); b.ue(0); b.ue(8)
    return b'\x42\x01' + b.finish()


def annex(nal): return b'\x00\x00\x01' + nal + b'\x00\x00\x01\x09\xf0'


def transport(nal, audio=False, scrambled=False):
    # Place SPS across a TS packet boundary; interleave another PID.
    elementary = b'\x00\x00\x01\x09\xf0' + b'\xff' * 165 + annex(nal) + b'\xff' * 600
    pes = b'\x00\x00\x01' + (b'\xc0' if audio else b'\xe0') + b'\x00\x00\x80\x00\x00' + elementary
    result = bytearray()
    for i in range(0, len(pes), 184):
        header = bytes([0x47, 0x41 if i == 0 else 0x01, 0x00, 0x90 if scrambled else 0x10])
        result += header + pes[i:i+184].ljust(184, b'\xff')
        result += b'\x47\x01\x01\x10' + b'\xff' * 184
    return bytes(result)


def box(name, payload): return (8 + len(payload)).to_bytes(4, 'big') + name + payload


def fixtures():
    entries = []
    def add(name, data, width=0, height=0):
        entries.append(dict(name=name, hex=data.hex(), width=width, height=height))
    for width, height in [(640, 360), (1280, 720), (1920, 1080)]:
        nal = avc(width, height, high=width == 1920)
        add(f'avc-{height}-annex', annex(nal), width, height)
        add(f'avc-{height}-ts-boundary', transport(nal), width, height)
    add('avc-1080-interlaced', transport(avc(1920, 1080, interlaced=True)), 1920, 1080)
    for cropped, layers in [(False, 0), (True, 2)]:
        nal = hevc(3840, 2160, cropped=cropped, layers=layers)
        add(f'hevc-4k-{cropped}-annex', annex(nal), 3840, 2160)
        add(f'hevc-4k-{cropped}-ts', transport(nal), 3840, 2160)
    nal = avc(1920, 1080, high=True)
    add('avcc-init', box(b'avcC', b'\x01\x64\x00\x28\xff\xe1' + len(nal).to_bytes(2, 'big') + nal), 1920, 1080)
    nal = hevc(3840, 2160)
    config = bytes([1]) + bytes(21) + b'\x01\xa1\x00\x01' + len(nal).to_bytes(2, 'big') + nal
    add('hvcc-init', box(b'hvcC', config), 3840, 2160)
    add('mpeg2-sequence', b'\x00\x00\x01\xb3\x78\x04\x38\x00', 1920, 1080)
    add('empty', b'')
    add('truncated', b'\x00\x00\x01\x67\x64\x00\x28')
    add('malformed-golomb', b'\x00\x00\x01\x67' + bytes(128))
    add('http-error-body', b'<html>Temporary failure</html>')
    add('scrambled-ts', transport(avc(1280, 720), scrambled=True))
    add('audio-not-video', transport(avc(1280, 720), audio=True))
    add('random-encrypted', bytes(range(256)) * 3)
    return entries


if __name__ == '__main__':
    path = Path(__file__).parent / 'tests' / 'fixtures' / 'resolution.json'
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(fixtures(), indent=2) + '\n')
    print(f'Generated {len(fixtures())} offline header fixtures')
