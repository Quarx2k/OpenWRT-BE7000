"""Patch only CPU1-3 handoff properties in the installing router's live FDT."""
import struct

def spin_table(data):
    if len(data) < 40:
        raise ValueError('Truncated DTB')
    h = list(struct.unpack_from('>10I', data))
    magic,total,st,strings,reserve,version,last,boot,ssize,tsize = h
    if magic != 0xd00dfeed or total > len(data) or version != 17:
        raise ValueError('Unsupported DTB header')
    if st+tsize > total or strings+ssize > total:
        raise ValueError('Invalid DTB ranges')
    names = bytearray(data[strings:strings+ssize])
    def nameoff(name):
        val=name.encode()+b'\0'
        for pos in range(len(names)):
            if (pos==0 or names[pos-1]==0) and names[pos:pos+len(val)]==val:return pos
        pos=len(names);names.extend(val);return pos
    def prop(name,value):
        return struct.pack('>III',3,len(value),nameoff(name))+value+b'\0'*((-len(value))%4)
    output=bytearray();stack=[];seen=set();pos=st
    while pos < st+tsize:
        token=struct.unpack_from('>I',data,pos)[0];start=pos;pos+=4
        if token==1:
            end=data.index(0,pos,st+tsize);name=data[pos:end].decode()
            pos=(end+4)&~3;stack.append(name)
            output.extend(data[start:pos])
            path='/'.join(stack)
            if path in ['/cpus/cpu@1','/cpus/cpu@2','/cpus/cpu@3']:
                seen.add(path);output.extend(prop('enable-method',b'spin-table\0'))
                output.extend(prop('cpu-release-addr',struct.pack('>Q',0x4fb3eff8)))
        elif token==2:
            stack.pop();output.extend(data[start:pos])
        elif token==3:
            size,off=struct.unpack_from('>II',data,pos);pos+=8
            end=names.index(0,off);name=bytes(names[off:end]).decode()
            pos=(pos+size+3)&~3
            path='/'.join(stack)
            if path in seen and name in ['enable-method','cpu-release-addr']:continue
            output.extend(data[start:pos])
        elif token==4:output.extend(data[start:pos])
        elif token==9:
            output.extend(data[start:pos]);break
        else:raise ValueError('Invalid FDT token')
    if len(seen)!=3 or stack:raise ValueError('Expected CPU1-3 in BE7000 DTB')
    end=reserve
    while end+16 <= total:
        a,b=struct.unpack_from('>QQ',data,end);end+=16
        if a==b==0:break
    else:raise ValueError('Missing memory reservation terminator')
    mem=data[reserve:end];newst=40+len(mem);newstrings=newst+len(output)
    size=max(65536,newstrings+len(names))
    header=struct.pack('>10I',magic,size,newst,newstrings,40,17,last,boot,len(names),len(output))
    result=header+mem+output+names
    return result+b'\0'*(size-len(result))
