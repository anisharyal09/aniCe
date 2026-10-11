# SPDX-License-Identifier: GPL-3.0-or-later
# Generates independent deterministic CBOR media fixtures for both native codecs.
import json, copy
from pathlib import Path
# Independent RFC 8949 encoder; deliberately does not import application codecs.
def head(m,n):
 if n<24:return bytes([m*32+n])
 for size,tag in [(1,24),(2,25),(4,26),(8,27)]:
  if n<1<<(8*size):return bytes([m*32+tag])+n.to_bytes(size,'big')
def enc(v):
 if isinstance(v,bool):return b'\xf5' if v else b'\xf4'
 if isinstance(v,int):return head(0,v) if v>=0 else head(1,-1-v)
 if isinstance(v,str):v=v.encode();return head(3,len(v))+v
 if isinstance(v,bytes):return head(2,len(v))+v
 if isinstance(v,list):return head(4,len(v))+b''.join(enc(x) for x in v)
 raise ValueError(v)
u='11111111-1111-4111-8111-111111111111';src='22222222-2222-4222-8222-222222222222';rev='33333333-3333-4333-8333-333333333333';cat='44444444-4444-4444-8444-444444444444'
def msg(k,f,v=1):return ['aniCe media',v,k,f]
snap=[u,src,rev,'Title 🎵','Artist','Player',1,10000,200000,1000,15,'',cat,[[src,'Player',1]],b'']
valid=[('capability',msg(1,[1,True])),('subscribe',msg(2,[u])),('ack',msg(3,[u])),('unsubscribe',msg(4,[u])),('snapshot',msg(5,snap)),('seek',msg(6,[u,1,src,rev,4,45000])),('auto',msg(6,[u,2,'',cat,6,0])),('select',msg(6,[u,3,src,cat,5,0])),('result',msg(7,[u,1,3])),('artwork',msg(8,[u,src,rev,bytes(32),2048,0,bytes(2048)]))]
empty=snap.copy();empty[1:3]=['',''];empty[3:6]=['','',''];empty[7:9]=[-1,-1];empty[10]=0;empty[13]=[];valid.append(('empty-snapshot',msg(5,empty)))
live=snap.copy();live[8]=-1;live[10]=7;valid.append(('live-stream',msg(5,live)))
invalid=[('version',msg(1,[1,False],2)),('kind',msg(9,[])),('short-capability',msg(1,[1])),('capability-boolean',msg(1,[1,1])),('short-uuid',msg(2,['x'])),('bad-uuid',msg(2,['x'*36])),('zero-command',msg(6,[u,0,src,rev,1,0])),('overflow-command',msg(6,[u,4294967296,src,rev,1,0])),('negative-seek',msg(6,[u,1,src,rev,4,-1])),('unknown-action',msg(6,[u,1,src,rev,7,0])),('unknown-result',msg(7,[u,1,8])),('oversized-art',msg(8,[u,src,rev,bytes(32),65537,0,b'x'])),('zero-art',msg(8,[u,src,rev,bytes(32),0,0,b'x'])),('chunk-overrun',msg(8,[u,src,rev,bytes(32),2,1,b'xx'])),('chunk-too-large',msg(8,[u,src,rev,bytes(32),4096,0,bytes(2049)])),('short-hash',msg(8,[u,src,rev,bytes(31),2,0,b'x']))]
for name,index,value in [('title-bound',3,'x'*513),('title-nul',3,'a\0b'),('position-bound',7,604800001),('negative-position',7,-2),('rate-bound',9,16001),('actions-bound',10,32),('duplicate-sources',13,[[src,'A',1],[src,'B',2]]),('inventory-bound',13,[[str(i).zfill(8)+'-1111-4111-8111-111111111111','A',1] for i in range(17)]),('mismatched-revision',2,'')]:
 fields=copy.deepcopy(snap);fields[index]=value;invalid.append((name,msg(5,fields)))
out={'oracle':'Independent Python RFC 8949 encoder; no native codec imports','valid':[{'name':n,'bytesHex':enc(v).hex(),'kind':v[2]} for n,v in valid],'invalid':[{'name':n,'bytesHex':enc(v).hex()} for n,v in invalid]}
out['invalid'] += [{'name':'truncated','bytesHex':enc(msg(5,snap)).hex()[:-2]},{'name':'oversized-record','bytesHex':enc(msg(8,[u,src,rev,bytes(32),65536,0,bytes(3900)])).hex()},{'name':'noncanonical-integer','bytesHex':(b'\x84'+enc('aniCe media')+b'\x18\x01'+enc(1)+enc([1,False])).hex()}]
(Path(__file__).resolve().parent.parent / 'protocol/test-vectors/media/media-vectors.json').write_text(json.dumps(out,indent=2)+'\n')
print(len(out['valid']),len(out['invalid']))
