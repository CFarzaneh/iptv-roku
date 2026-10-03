#!/usr/bin/env python3
"""Inspect one configured Xtream live stream without printing secrets or URLs."""

from __future__ import annotations

import argparse
import json
import re
import urllib.parse
import urllib.request
from pathlib import Path


STREAM_TYPES = {
    0x01: "MPEG-1 video",
    0x02: "MPEG-2 video",
    0x03: "MPEG-1 audio",
    0x04: "MPEG-2 audio",
    0x0F: "AAC",
    0x11: "AAC-LATM",
    0x1B: "H.264/AVC",
    0x24: "H.265/HEVC",
    0x81: "AC-3 (private mapping)",
    0x87: "E-AC-3 (private mapping)",
}


def fetch(url: str, user_agent: str, limit: int) -> tuple[int, str, str, bytes]:
    request = urllib.request.Request(url, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(request, timeout=15) as response:
        return (
            response.status,
            response.headers.get("Content-Type", ""),
            response.geturl(),
            response.read(limit),
        )


def packet_payload(packet: bytes):
    if len(packet) != 188 or packet[0] != 0x47:
        return None, False, b""
    pid = ((packet[1] & 0x1F) << 8) | packet[2]
    payload_start = bool(packet[1] & 0x40)
    adaptation_control = (packet[3] >> 4) & 0x03
    offset = 4
    if adaptation_control in (2, 3):
        offset += 1 + packet[4]
    if adaptation_control not in (1, 3) or offset >= 188:
        return pid, payload_start, b""
    return pid, payload_start, packet[offset:]


def psi_section(payload: bytes, payload_start: bool) -> bytes:
    if not payload_start or not payload:
        return b""
    pointer = payload[0]
    return payload[1 + pointer :]


class BitReader:
    def __init__(self, data: bytes):
        self.data = data
        self.bit = 0

    def read(self, count: int) -> int:
        value = 0
        for _ in range(count):
            value = (value << 1) | ((self.data[self.bit // 8] >> (7 - self.bit % 8)) & 1)
            self.bit += 1
        return value

    def ue(self) -> int:
        zeroes = 0
        while self.read(1) == 0:
            zeroes += 1
        return (1 << zeroes) - 1 + (self.read(zeroes) if zeroes else 0)

    def se(self) -> int:
        value = self.ue()
        return (value + 1) // 2 if value & 1 else -(value // 2)


def skip_scaling_list(bits: BitReader, size: int) -> None:
    last_scale = 8
    next_scale = 8
    for _ in range(size):
        if next_scale:
            next_scale = (last_scale + bits.se() + 256) % 256
        last_scale = next_scale or last_scale


def parse_h264_sps(nal: bytes) -> dict[str, object]:
    cleaned = bytearray()
    zeroes = 0
    for byte in nal[1:]:
        if zeroes >= 2 and byte == 3:
            zeroes = 0
            continue
        cleaned.append(byte)
        zeroes = zeroes + 1 if byte == 0 else 0
    bits = BitReader(bytes(cleaned))
    profile = bits.read(8)
    constraints = bits.read(8)
    level = bits.read(8)
    bits.ue()
    chroma_format = 1
    separate_colour_plane = 0
    bit_depth_luma = 8
    bit_depth_chroma = 8
    if profile in {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135}:
        chroma_format = bits.ue()
        if chroma_format == 3:
            separate_colour_plane = bits.read(1)
        bit_depth_luma = bits.ue() + 8
        bit_depth_chroma = bits.ue() + 8
        bits.read(1)
        if bits.read(1):
            count = 8 if chroma_format != 3 else 12
            for index in range(count):
                if bits.read(1):
                    skip_scaling_list(bits, 16 if index < 6 else 64)
    bits.ue()
    picture_order = bits.ue()
    if picture_order == 0:
        bits.ue()
    elif picture_order == 1:
        bits.read(1)
        bits.se()
        bits.se()
        for _ in range(bits.ue()):
            bits.se()
    max_reference_frames = bits.ue()
    bits.read(1)
    width_mbs = bits.ue() + 1
    height_map_units = bits.ue() + 1
    frame_mbs_only = bits.read(1)
    if not frame_mbs_only:
        bits.read(1)
    bits.read(1)
    crop_left = crop_right = crop_top = crop_bottom = 0
    if bits.read(1):
        crop_left = bits.ue()
        crop_right = bits.ue()
        crop_top = bits.ue()
        crop_bottom = bits.ue()
    chroma_array = 0 if separate_colour_plane else chroma_format
    sub_width = 1 if chroma_array in (0, 3) else 2
    sub_height = 2 if chroma_array == 1 else 1
    crop_unit_x = 1 if chroma_array == 0 else sub_width
    crop_unit_y = (2 - frame_mbs_only) if chroma_array == 0 else sub_height * (2 - frame_mbs_only)
    width = width_mbs * 16 - crop_unit_x * (crop_left + crop_right)
    height = height_map_units * 16 * (2 - frame_mbs_only) - crop_unit_y * (crop_top + crop_bottom)
    profile_names = {66: "Baseline", 77: "Main", 88: "Extended", 100: "High", 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4"}
    return {
        "profile": profile_names.get(profile, str(profile)),
        "constraints": f"0x{constraints:02x}",
        "level": f"{level / 10:.1f}",
        "resolution": f"{width}x{height}",
        "scan": "progressive" if frame_mbs_only else "interlaced/field-coded",
        "chroma_format_idc": chroma_format,
        "bit_depth": f"{bit_depth_luma}/{bit_depth_chroma}",
        "max_reference_frames": max_reference_frames,
    }


def elementary_stream(packets: list[bytes], wanted_pid: int) -> bytes:
    chunks = []
    for packet in packets:
        pid, payload_start, payload = packet_payload(packet)
        if pid != wanted_pid or not payload:
            continue
        if payload_start and len(payload) >= 9 and payload[:3] == b"\x00\x00\x01":
            payload = payload[9 + payload[8] :]
        chunks.append(payload)
    return b"".join(chunks)


def find_h264_sps(data: bytes) -> dict[str, object]:
    for marker in (b"\x00\x00\x00\x01", b"\x00\x00\x01"):
        start = 0
        while True:
            offset = data.find(marker, start)
            if offset < 0:
                break
            nal_start = offset + len(marker)
            if nal_start < len(data) and data[nal_start] & 0x1F == 7:
                endings = [x for x in (data.find(b"\x00\x00\x01", nal_start + 1), data.find(b"\x00\x00\x00\x01", nal_start + 1)) if x >= 0]
                nal_end = min(endings) if endings else len(data)
                try:
                    return parse_h264_sps(data[nal_start:nal_end])
                except (IndexError, ValueError):
                    return {"parse_error": True}
            start = nal_start + 1
    return {}


def find_adts(data: bytes) -> dict[str, object]:
    rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    for offset in range(len(data) - 7):
        if data[offset] == 0xFF and data[offset + 1] & 0xF6 == 0xF0:
            object_type = ((data[offset + 2] >> 6) & 0x03) + 1
            rate_index = (data[offset + 2] >> 2) & 0x0F
            channels = ((data[offset + 2] & 1) << 2) | ((data[offset + 3] >> 6) & 3)
            return {
                "aac_object_type": object_type,
                "sample_rate": rates[rate_index] if rate_index < len(rates) else "reserved",
                "channels": channels,
            }
    return {}


def inspect_transport_stream(data: bytes) -> list[dict[str, object]]:
    sync_offset = next(
        (
            offset
            for offset in range(min(188, len(data)))
            if offset + 188 < len(data)
            and data[offset] == 0x47
            and data[offset + 188] == 0x47
        ),
        None,
    )
    if sync_offset is None:
        return []
    packets = [
        data[offset : offset + 188]
        for offset in range(sync_offset, len(data) - 187, 188)
    ]

    pmt_pid = None
    for packet in packets:
        pid, payload_start, payload = packet_payload(packet)
        if pid != 0:
            continue
        section = psi_section(payload, payload_start)
        if len(section) < 12 or section[0] != 0:
            continue
        section_end = min(3 + (((section[1] & 0x0F) << 8) | section[2]) - 4, len(section))
        offset = 8
        while offset + 4 <= section_end:
            program = (section[offset] << 8) | section[offset + 1]
            candidate = ((section[offset + 2] & 0x1F) << 8) | section[offset + 3]
            if program:
                pmt_pid = candidate
                break
            offset += 4
        if pmt_pid is not None:
            break

    tracks = []
    if pmt_pid is None:
        return tracks
    for packet in packets:
        pid, payload_start, payload = packet_payload(packet)
        if pid != pmt_pid:
            continue
        section = psi_section(payload, payload_start)
        if len(section) < 16 or section[0] != 2:
            continue
        section_end = min(3 + (((section[1] & 0x0F) << 8) | section[2]) - 4, len(section))
        offset = 12 + (((section[10] & 0x0F) << 8) | section[11])
        while offset + 5 <= section_end:
            stream_type = section[offset]
            pid = ((section[offset + 1] & 0x1F) << 8) | section[offset + 2]
            descriptor_length = ((section[offset + 3] & 0x0F) << 8) | section[offset + 4]
            track = {
                "pid": pid,
                "type": f"0x{stream_type:02x}",
                "codec": STREAM_TYPES.get(stream_type, "unknown/private"),
            }
            stream = elementary_stream(packets, pid)
            if stream_type == 0x1B:
                track["h264"] = find_h264_sps(stream)
            elif stream_type in (0x0F, 0x11):
                track["aac"] = find_adts(stream)
            tracks.append(track)
            offset += 5 + descriptor_length
        break
    return tracks


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("channel_name")
    parser.add_argument("--config", default="config.json")
    args = parser.parse_args()

    account = json.loads(Path(args.config).read_text())["xtream"]
    server = account["server"].rstrip("/")
    credentials = urllib.parse.urlencode(
        {
            "username": account["username"],
            "password": account["password"],
            "action": "get_live_streams",
        }
    )
    api_url = f"{server}/player_api.php?{credentials}"
    _, _, _, body = fetch(api_url, "Mozilla/5.0", 30_000_000)
    streams = json.loads(body)
    exact = [row for row in streams if str(row.get("name", "")).casefold() == args.channel_name.casefold()]
    partial = [row for row in streams if args.channel_name.casefold() in str(row.get("name", "")).casefold()]
    query_tokens = {
        token
        for token in re.findall(r"[a-z0-9]+", args.channel_name.casefold())
        if token not in {"us", "tv", "hd", "fhd"}
    }
    fuzzy = [
        row
        for row in streams
        if query_tokens
        and query_tokens.issubset(
            set(re.findall(r"[a-z0-9]+", str(row.get("name", "")).casefold()))
        )
    ]
    matches = exact or partial or fuzzy
    print("catalog_matches", len(matches))
    if not matches:
        raise SystemExit("No matching channel was found")

    category_query = urllib.parse.urlencode(
        {
            "username": account["username"],
            "password": account["password"],
            "action": "get_live_categories",
        }
    )
    _, _, _, category_body = fetch(
        f"{server}/player_api.php?{category_query}", "Mozilla/5.0", 2_000_000
    )
    categories = {
        str(row.get("category_id", "")): str(row.get("category_name", ""))
        for row in json.loads(category_body)
    }

    user = urllib.parse.quote(account["username"], safe="")
    password = urllib.parse.quote(account["password"], safe="")
    for row in matches[:10]:
        stream_id = str(row.get("stream_id", ""))
        category_id = str(row.get("category_id", ""))
        print(
            "match",
            json.dumps(
                {
                    "name": row.get("name", ""),
                    "stream_id": stream_id,
                    "category": categories.get(category_id, category_id),
                    "provider_stream_type": row.get("stream_type", ""),
                    "direct_source_set": bool(row.get("direct_source")),
                }
            ),
        )
        if not stream_id.isdigit():
            continue
        manifest_url = f"{server}/live/{user}/{password}/{stream_id}.m3u8"
        try:
            status, content_type, final_url, manifest = fetch(
                manifest_url, "Roku/DVP-15.0 (15.0.0.0)", 1_000_000
            )
            text = manifest.decode("utf-8", "replace")
            media_lines = [
                line.strip()
                for line in text.splitlines()
                if line.strip() and not line.startswith("#")
            ]
            tags = [line.strip() for line in text.splitlines() if line.startswith("#")]
            media_parts = [urllib.parse.urlsplit(urllib.parse.urljoin(final_url, line)) for line in media_lines]
            print(
                "manifest",
                json.dumps(
                    {
                        "status": status,
                        "content_type": content_type,
                        "is_hls": text.startswith("#EXTM3U"),
                        "version": next((tag for tag in tags if tag.startswith("#EXT-X-VERSION")), ""),
                        "target_duration": next((tag for tag in tags if tag.startswith("#EXT-X-TARGETDURATION")), ""),
                        "media_entries": len(media_lines),
                        "ends_with_newline": text.endswith("\n"),
                        "absolute_media_urls": sum(1 for line in media_lines if urllib.parse.urlsplit(line).scheme),
                        "media_path_extensions": sorted({Path(part.path).suffix or "<none>" for part in media_parts}),
                        "media_hosts_match_manifest": all(part.netloc == urllib.parse.urlsplit(final_url).netloc for part in media_parts),
                    }
                ),
            )
            if not media_lines:
                continue
            segment_url = urllib.parse.urljoin(final_url, media_lines[0])
            segment_status, segment_type, _, segment = fetch(
                segment_url, "Roku/DVP-15.0 (15.0.0.0)", 4_000_000
            )
            print(
                "segment",
                json.dumps(
                    {
                        "status": segment_status,
                        "content_type": segment_type,
                        "bytes_inspected": len(segment),
                        "tracks": inspect_transport_stream(segment),
                    }
                ),
            )
        except Exception as error:
            print("playback_probe_error", getattr(error, "code", type(error).__name__))

        direct_url = f"{server}/live/{user}/{password}/{stream_id}.ts"
        try:
            direct_status, direct_type, _, direct_data = fetch(
                direct_url, "Roku/DVP-15.0 (15.0.0.0)", 4_000_000
            )
            print(
                "direct_ts",
                json.dumps(
                    {
                        "status": direct_status,
                        "content_type": direct_type,
                        "bytes_inspected": len(direct_data),
                        "tracks": inspect_transport_stream(direct_data),
                    }
                ),
            )
        except Exception as error:
            print("direct_ts_probe_error", getattr(error, "code", type(error).__name__))


if __name__ == "__main__":
    main()
