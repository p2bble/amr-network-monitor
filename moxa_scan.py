import socket

def tlv(t,v): l=len(v); return (bytes([t,l])+v if l<128 else bytes([t,0x81,l])+v)
def enc(parts):
    b=bytes([40*parts[0]+parts[1]])
    for v in parts[2:]:
        if v<128: b+=bytes([v])
        else:
            c=[]; t=v
            while t: c.insert(0,t&0x7f); t>>=7
            b+=bytes([(x|0x80 if i<len(c)-1 else x) for i,x in enumerate(c)])
    return b

def get(host, oid_str):
    parts=[int(x) for x in oid_str.split('.')]
    oid_b=tlv(0x06,enc(parts))
    pdu=tlv(0xa0,tlv(0x02,bytes([1]))+bytes([2,1,0,2,1,0])+tlv(0x30,tlv(0x30,oid_b+bytes([5,0]))))
    msg=tlv(0x30,bytes([2,1,1])+tlv(0x04,b'public')+pdu)
    try:
        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2)
        s.sendto(msg,(host,161)); d,_=s.recvfrom(4096); s.close()
        i=d.find(oid_b)+len(oid_b); vt,vl=d[i],d[i+1]; raw=d[i+2:i+2+vl]
        if vt==4: return raw.decode(errors='replace').strip()
        return str(int.from_bytes(raw,'big'))
    except Exception as e: return 'ERR:'+str(e)

H='192.168.145.51'
base='1.3.6.1.4.1.8691.15.35.1.3.1'
skip={'0','ERR:timed out'}
print('Scanning MOXA',H,'...')
for sub in range(1,20):
    for idx in ['1.0','1.1','2.0','2.1']:
        oid=base+'.'+str(sub)+'.'+idx
        v=get(H,oid)
        if v not in skip and not v.startswith('ERR:'):
            print(oid,'=',v)
print('Done')
