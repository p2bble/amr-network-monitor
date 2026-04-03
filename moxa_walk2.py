#!/usr/bin/env python3
"""
MOXA AWK-1137C SNMP Walk - 1.5.3.1 프로파일 status 테이블
현재 연결된 AP의 채널/SSID/BSSID 관련 OID 탐색
"""
import socket

HOST      = '192.168.145.51'
COMMUNITY = b'public'

# Walk 대상 서브트리 목록
TARGETS = [
    ([1,3,6,1,4,1,8691,15,35,1,5,2],   "1.5.2 BSS table"),
    ([1,3,6,1,4,1,8691,15,35,1,5,4],   "1.5.4 WLAN unknown"),
    ([1,3,6,1,4,1,8691,15,35,1,5,5],   "1.5.5 WLAN unknown"),
    ([1,3,6,1,4,1,8691,15,35,1,8],     "1.8 unknown"),
    ([1,3,6,1,4,1,8691,15,35,1,9],     "1.9 unknown"),
    ([1,3,6,1,4,1,8691,15,35,1,10],    "1.10 unknown"),
    ([1,3,6,1,4,1,8691,15,35,1,11],    "1.11 unknown"),
]

def tlv(t, v):
    l = len(v)
    if l < 128:   return bytes([t, l]) + v
    elif l < 256: return bytes([t, 0x81, l]) + v
    else:         return bytes([t, 0x82, l >> 8, l & 0xff]) + v

def enc_oid(parts):
    b = bytes([40 * parts[0] + parts[1]])
    for v in parts[2:]:
        if v < 128:
            b += bytes([v])
        else:
            c = []; t = v
            while t: c.insert(0, t & 0x7f); t >>= 7
            b += bytes([(x | 0x80 if i < len(c)-1 else x) for i, x in enumerate(c)])
    return b

def dec_oid(data, offset):
    parts = []
    first = data[offset]
    parts += [first // 40, first % 40]
    offset += 1
    val = 0
    while offset < len(data):
        b = data[offset]; offset += 1
        val = (val << 7) | (b & 0x7f)
        if not (b & 0x80): parts.append(val); val = 0
    return parts

def parse_tlv(data, offset):
    tag = data[offset]; offset += 1
    l   = data[offset]; offset += 1
    if l & 0x80:
        n = l & 0x7f
        l = int.from_bytes(data[offset:offset+n], 'big')
        offset += n
    return tag, data[offset:offset+l], offset + l

def getnext(oid_parts):
    oid_b   = tlv(0x06, enc_oid(oid_parts))
    varbind = tlv(0x30, oid_b + bytes([5, 0]))
    pdu     = tlv(0xa1, tlv(0x02, bytes([1])) + bytes([2,1,0,2,1,0]) + tlv(0x30, varbind))
    msg     = tlv(0x30, bytes([2,1,1]) + tlv(0x04, COMMUNITY) + pdu)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    s.sendto(msg, (HOST, 161))
    data, _ = s.recvfrom(4096)
    s.close()
    _, seq_val, _ = parse_tlv(data, 0)
    off = 0
    _, _, off = parse_tlv(seq_val, off)
    _, _, off = parse_tlv(seq_val, off)
    _, pdu_val, _ = parse_tlv(seq_val, off)
    off2 = 0
    _, _, off2 = parse_tlv(pdu_val, off2)
    _, _, off2 = parse_tlv(pdu_val, off2)
    _, _, off2 = parse_tlv(pdu_val, off2)
    _, vblist_val, _ = parse_tlv(pdu_val, off2)
    _, vb_val,    _  = parse_tlv(vblist_val, 0)
    oid_tag, oid_raw, off3 = parse_tlv(vb_val, 0)
    ret_oid = dec_oid(oid_raw, 0)
    val_tag, val_raw, _ = parse_tlv(vb_val, off3)
    if val_tag == 0x05: return ret_oid, 'NULL'
    if val_tag == 0x82: return ret_oid, 'endOfMib'
    if val_tag == 4:    return ret_oid, repr(val_raw.decode(errors='replace').strip())
    if val_tag in (2, 0x41, 0x42, 0x43):
        n = int.from_bytes(val_raw, 'big')
        if val_tag == 2 and val_raw and (val_raw[0] & 0x80):
            n -= (1 << (8 * len(val_raw)))
        return ret_oid, str(n)
    return ret_oid, val_raw.hex()

def walk(prefix, label, limit=300):
    print(f"\n{'='*60}")
    print(f"Walking {label}")
    print(f"Prefix: {'.'.join(map(str, prefix))}")
    print('='*60)
    current = prefix[:]
    count   = 0
    try:
        while True:
            ret_oid, val = getnext(current)
            oid_str = '.'.join(map(str, ret_oid))
            if ret_oid[:len(prefix)] != prefix:
                print('--- end of subtree ---')
                break
            # 비어있거나 0인 값도 모두 출력
            print(f"{oid_str}  =  {val}")
            current = ret_oid
            count  += 1
            if count >= limit:
                print(f'--- limit({limit}) reached ---')
                break
    except Exception as e:
        print(f'Error at {".".join(map(str, current))}: {e}')
    print(f'Total OIDs: {count}')

if __name__ == "__main__":
    print(f"Target MOXA: {HOST}")
    for prefix, label in TARGETS:
        walk(prefix, label)
