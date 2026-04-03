import socket

HOST = '192.168.145.51'
COMMUNITY = b'public'

def tlv(t, v):
    l = len(v)
    if l < 128: return bytes([t, l]) + v
    elif l < 256: return bytes([t, 0x81, l]) + v
    else: return bytes([t, 0x82, l >> 8, l & 0xff]) + v

def enc_oid(parts):
    b = bytes([40 * parts[0] + parts[1]])
    for v in parts[2:]:
        if v < 128:
            b += bytes([v])
        else:
            c = []; t = v
            while t: c.insert(0, t & 0x7f); t >>= 7
            b += bytes([(x | 0x80 if i < len(c) - 1 else x) for i, x in enumerate(c)])
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
        if not (b & 0x80):
            parts.append(val); val = 0
    return parts

def parse_tlv(data, offset):
    tag = data[offset]; offset += 1
    l = data[offset]; offset += 1
    if l & 0x80:
        n = l & 0x7f
        l = int.from_bytes(data[offset:offset+n], 'big')
        offset += n
    return tag, data[offset:offset+l], offset + l

def getnext(oid_parts):
    oid_b = tlv(0x06, enc_oid(oid_parts))
    varbind = tlv(0x30, oid_b + bytes([5, 0]))
    pdu = tlv(0xa1, tlv(0x02, bytes([1])) + bytes([2,1,0,2,1,0]) + tlv(0x30, varbind))
    msg = tlv(0x30, bytes([2,1,1]) + tlv(0x04, COMMUNITY) + pdu)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    s.sendto(msg, (HOST, 161))
    data, _ = s.recvfrom(4096)
    s.close()
    # parse response: SEQUENCE > version + community + GetResponse PDU
    _, seq_val, _ = parse_tlv(data, 0)
    off = 0
    _, _, off = parse_tlv(seq_val, off)  # version
    _, _, off = parse_tlv(seq_val, off)  # community
    _, pdu_val, _ = parse_tlv(seq_val, off)  # PDU
    off2 = 0
    _, _, off2 = parse_tlv(pdu_val, off2)  # req-id
    _, _, off2 = parse_tlv(pdu_val, off2)  # error-status
    _, _, off2 = parse_tlv(pdu_val, off2)  # error-index
    _, vblist_val, _ = parse_tlv(pdu_val, off2)
    _, vb_val, _ = parse_tlv(vblist_val, 0)
    # vb = OID + value
    oid_tag, oid_raw, off3 = parse_tlv(vb_val, 0)
    ret_oid = dec_oid(oid_raw, 0)
    val_tag, val_raw, _ = parse_tlv(vb_val, off3)
    if val_tag == 0x05: return ret_oid, 'NULL'
    if val_tag == 0x82: return ret_oid, 'endOfMib'
    if val_tag == 4: return ret_oid, val_raw.decode(errors='replace').strip()
    if val_tag in (2, 0x41, 0x42, 0x43):
        n = int.from_bytes(val_raw, 'big')
        if val_tag == 2 and val_raw and (val_raw[0] & 0x80):
            n -= (1 << (8 * len(val_raw)))
        return ret_oid, str(n)
    return ret_oid, val_raw.hex()

# Continue from end of previous walk, show all values including 0
START   = [1,3,6,1,4,1,8691,15,35,1,7,12,1,18,2]
PREFIX  = [1,3,6,1,4,1,8691,15,35]
current = START[:]

print('Walking subtree', '.'.join(map(str, PREFIX)))
count = 0
try:
    while True:
        ret_oid, val = getnext(current)
        oid_str = '.'.join(map(str, ret_oid))
        if ret_oid[:len(PREFIX)] != PREFIX:
            print('--- end of subtree ---')
            break
        # Show all values
        print(oid_str, '=', val)
        current = ret_oid
        count += 1
        if count > 2000:
            print('--- limit reached, last OID:', oid_str, '---')
            break
except Exception as e:
    print('Error at', '.'.join(map(str, current)), ':', e)
print('Total OIDs walked:', count)
