#!/usr/bin/env python3
"""Print package, versionCode and versionName of an APK as KEY=VALUE lines.

Parses the compiled (binary XML) AndroidManifest.xml directly, so no Android
SDK tools (aapt/apkanalyzer) are needed on the runner.

Usage: apk_manifest.py <file.apk>
"""
import struct
import sys
import zipfile

RES_STRING_POOL_TYPE = 0x0001
RES_XML_TYPE = 0x0003
RES_XML_START_ELEMENT_TYPE = 0x0102
RES_XML_RESOURCE_MAP_TYPE = 0x0180
UTF8_FLAG = 0x100

ATTR_VERSION_CODE = 0x0101021B
ATTR_VERSION_NAME = 0x0101021C

TYPE_STRING = 0x03
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11


def _decode_length(data, pos, utf8):
    if utf8:
        n = data[pos]
        if n & 0x80:
            n = ((n & 0x7F) << 8) | data[pos + 1]
            pos += 2
        else:
            pos += 1
        return n, pos
    n = struct.unpack_from("<H", data, pos)[0]
    if n & 0x8000:
        n = ((n & 0x7FFF) << 16) | struct.unpack_from("<H", data, pos + 2)[0]
        pos += 4
    else:
        pos += 2
    return n, pos


def _string_pool(data, off):
    _, header_size, _ = struct.unpack_from("<HHI", data, off)
    count, _styles, flags, strings_start, _ = struct.unpack_from("<IIIII", data, off + 8)
    utf8 = bool(flags & UTF8_FLAG)
    offsets = struct.unpack_from(f"<{count}I", data, off + header_size)
    base = off + strings_start
    out = []
    for o in offsets:
        pos = base + o
        if utf8:
            _chars, pos = _decode_length(data, pos, True)  # UTF-16 length
            nbytes, pos = _decode_length(data, pos, True)  # UTF-8 byte length
            out.append(data[pos:pos + nbytes].decode("utf-8", "replace"))
        else:
            nchars, pos = _decode_length(data, pos, False)
            out.append(data[pos:pos + nchars * 2].decode("utf-16-le", "replace"))
    return out


def parse_manifest(data):
    type_, header_size, size = struct.unpack_from("<HHI", data, 0)
    if type_ != RES_XML_TYPE:
        raise ValueError("AndroidManifest.xml is not binary XML")
    strings, res_ids = [], []
    off = header_size
    while off + 8 <= min(size, len(data)):
        ctype, chdr, csize = struct.unpack_from("<HHI", data, off)
        if csize < 8:
            break
        if ctype == RES_STRING_POOL_TYPE:
            strings = _string_pool(data, off)
        elif ctype == RES_XML_RESOURCE_MAP_TYPE:
            n = (csize - chdr) // 4
            res_ids = list(struct.unpack_from(f"<{n}I", data, off + chdr))
        elif ctype == RES_XML_START_ELEMENT_TYPE:
            ext = off + chdr
            _ns, name_idx, attr_start, attr_size, attr_count = struct.unpack_from("<IIHHH", data, ext)
            if strings[name_idx] != "manifest":
                off += csize
                continue
            info = {}
            for i in range(attr_count):
                a = ext + attr_start + i * attr_size
                _ans, aname, raw, _vsize, _res0, vtype, vdata = struct.unpack_from("<IIIHBBI", data, a)
                res_id = res_ids[aname] if aname < len(res_ids) else None
                name = strings[aname] if aname < len(strings) else ""
                if vtype == TYPE_STRING:
                    value = strings[vdata]
                elif raw != 0xFFFFFFFF and raw < len(strings):
                    value = strings[raw]
                else:
                    value = vdata
                if res_id == ATTR_VERSION_CODE or name == "versionCode":
                    info["versionCode"] = int(value) if vtype in (TYPE_INT_DEC, TYPE_INT_HEX) else int(str(value), 0)
                elif res_id == ATTR_VERSION_NAME or name == "versionName":
                    info["versionName"] = str(value)
                elif name == "package":
                    info["package"] = str(value)
            return info
        off += csize
    raise ValueError("no <manifest> element found")


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with zipfile.ZipFile(sys.argv[1]) as z:
        info = parse_manifest(z.read("AndroidManifest.xml"))
    for key in ("package", "versionCode", "versionName"):
        print(f"{key}={info.get(key, '')}")
    return 0 if info.get("package") and "versionCode" in info else 1


if __name__ == "__main__":
    sys.exit(main())
