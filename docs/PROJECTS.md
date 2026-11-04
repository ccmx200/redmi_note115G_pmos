import struct, os
RAW="/mnt/d/evergo/rom/super.raw"; OUT="/mnt/d/evergo/rom/parts"
os.makedirs(OUT, exist_ok=True)
f=open(RAW,"rb")
def r(off,n): f.seek(off); return f.read(n)
def u32(off): return struct.unpack("<I", r(off,4))[0]
md=12288
hdr_size=u32(md+8)
base=md+hdr_size
tbase=md+80
tabs=[]
for i in range(4):
    off=u32(tbase+i*12); cnt=u32(tbase+i*12+4); esz=u32(tbase+i*12+8)
    tabs.append((off,cnt,esz)); print("table",i,"off",off,"cnt",cnt,"esz",esz)
pt,et,gt,bt=tabs
def ents(tab):
    off,cnt,esz=tab
    return r(base+off,cnt*esz),esz
pdata,psz=ents(pt)
parts=[]
for i in range(pt[1]):
    e=pdata[i*psz:(i+1)*psz]
    name=e[:36].split(b"\x00")[0].decode()
    attrs,fe,ne,gi=struct.unpack_from("<IIII",e,36)
    parts.append((name,fe,ne,gi)); print("part",i,name,ne,fe)
edata,esz=ents(et)
ext=[]
for i in range(et[1]):
    e=edata[i*esz:(i+1)*esz]
    num,ttype,tdata,tsrc=struct.unpack_from("<QIQI",e,0)
    ext.append((num,ttype,tdata,tsrc))
print("extents",len(ext))
for name,fe,ne,gi in parts:
    path=os.path.join(OUT,name+".img")
    with open(path,"wb") as out:
        for i in range(fe,fe+ne):
            num,ttype,tdata,tsrc=ext[i]
            if ttype==0:
                f.seek(tdata*512); left=num*512
                while left>0:
                    ch=f.read(min(left,4<<20))
                    if not ch: break
                    out.write(ch); left-=len(ch)
            else:
                out.write(b"\x00"*(num*512))
    print("extracted",name,os.path.getsize(path))
f.close()