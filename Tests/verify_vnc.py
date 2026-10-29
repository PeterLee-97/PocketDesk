#!/usr/bin/env python3
"""Independent RFB fixture: authentication, a real decoded frame, pointer/key/scroll packets."""
from pathlib import Path
import socket, struct, subprocess, threading
root = Path(__file__).resolve().parents[1]
binary = root / 'build/setup/vnc-integration'
binary.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcrun','swiftc',str(root/'PocketDesk/Apps/RemoteDesktop/VNCClient.swift'),str(root/'Tests/VNCIntegration.swift'),'-o',str(binary)],check=True)
listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(1)
port=listener.getsockname()[1]
errors=[];observed=[]
def serve():
 try:
  s,_=listener.accept();s.settimeout(6)
  with s:
   def read(n):
    b=b''
    while len(b)<n:
     x=s.recv(n-len(b))
     if not x: raise EOFError()
     b+=x
    return b
   s.sendall(b'RFB 003.008\n');assert read(12)==b'RFB 003.008\n'
   s.sendall(b'\x01\x02');assert read(1)==b'\x02'
   challenge=bytes(range(16));s.sendall(challenge)
   key=bytes(int(f'{b:08b}'[::-1],2) for b in b'test1234')
   expected=subprocess.run(['/usr/bin/openssl','enc','-des-ecb','-K',key.hex(),'-nopad'],input=challenge,capture_output=True,check=True).stdout
   assert read(16)==expected,'DES authentication response'
   s.sendall(b'\0'*4);assert read(1)==b'\x01'
   pixel_format=struct.pack('>BBBBHHHBBBxxx',32,24,0,1,255,255,255,16,8,0)
   s.sendall(struct.pack('>HH',4,3)+pixel_format+struct.pack('>I',7)+b'Fixture')
   frame_sent=False
   while True:
    typ=read(1)[0]
    if typ==0: read(19)
    elif typ==2: h=read(3);read(int.from_bytes(h[1:],'big')*4)
    elif typ==3:
     read(9)
     if not frame_sent:
      frame_sent=True;s.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',0,0,4,3,0)+bytes([0,0,255,0])*12)
    elif typ==4:
     b=read(7);observed.append(('key',b[0],int.from_bytes(b[3:],'big')))
    elif typ==5:
     b=read(5);observed.append(('pointer',b[0],*struct.unpack('>HH',b[1:])))
    else: raise AssertionError(f'Unexpected packet {typ}')
 except EOFError: pass
 except Exception as e: errors.append(repr(e))
thread=threading.Thread(target=serve,daemon=True);thread.start()
result=subprocess.run([str(binary),str(port)],capture_output=True,text=True,timeout=12)
thread.join(2);listener.close()
print(result.stdout.strip())
assert result.returncode==0,(result.returncode,result.stderr)
assert not errors,errors
for expected in [('key',1,0xFF08),('key',0,0xFF08),('pointer',1,2,1),('pointer',0,2,1),('pointer',0x20,2,1)]: assert expected in observed,(expected,observed)
keys=[event for event in observed if event[0]=='key']
assert keys[-4:]==[('key',1,0xFFE3),('key',1,0x20),('key',0,0x20),('key',0,0xFFE3)],keys
print('PASS: RFB authentication, frame decode, single click, Backspace, horizontal wheel, Mac input-source Ctrl+Space; no deadlock')
