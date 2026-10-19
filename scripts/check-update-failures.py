#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise packaged updater failure/recovery on disposable copies.
import hashlib,http.server,json,os,pathlib,shutil,socket,subprocess,sys,tempfile,threading
repo=pathlib.Path(__file__).resolve().parents[1]
image=pathlib.Path(sys.argv[1]).resolve()
work=pathlib.Path(tempfile.mkdtemp(prefix='pd-update-failures.'))
subprocess.run([str(image),'--appimage-extract'],cwd=work,stdout=subprocess.DEVNULL,check=True)
root=work/'squashfs-root/usr';helper=root/'app/PerformanceDashboard.app/gp-update-helper'
env=dict(os.environ,LD_LIBRARY_PATH=str(root/'runtime/lib'),GNUSTEP_CONFIG_FILE=str(root/'runtime/etc/GNUstep/GNUstep.conf'),PATH='/usr/bin:/bin')
install=work/'installed';install.mkdir();current=install/'PerformanceDashboard.AppImage';shutil.copy2(image,current)
digest=hashlib.sha256(image.read_bytes()).hexdigest()
base={'package':{},'asset':{'backend':'appimage','name':image.name,'url':image.as_uri(),'sha256':digest},'execution':{'workingRoot':str(work/'updater'),'linux':{'currentAppImagePath':str(current)}}}
plan=work/'plan.json';state=work/'state.json'
def prepare(label,expected):
 plan.write_text(json.dumps(base));p=subprocess.run([str(helper),'--mode','prepare','--plan',str(plan),'--state-file',str(state)],env=env,capture_output=True)
 result=json.loads(state.read_text());assert result['status']==expected,(label,p.returncode,result)
 assert hashlib.sha256(current.read_bytes()).hexdigest()==digest
 shutil.copy2(state,work/(label+'.json'));print(label,expected,flush=True)
base['asset']['sha256']='0'*64;prepare('bad-hash','failed')
base['asset']['sha256']=digest;prepare('same-state-retry','readyToApply')
install.chmod(0o555)
try:prepare('unwritable-directory','manualActionRequired')
finally:install.chmod(0o755)
class Partial(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200);self.send_header('Content-Length',str(image.stat().st_size));self.end_headers();self.wfile.write(image.read_bytes()[:8192]);self.wfile.flush();self.connection.shutdown(socket.SHUT_RDWR);self.connection.close()
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Partial);threading.Thread(target=server.serve_forever,daemon=True).start()
base['asset']['url']='http://127.0.0.1:%d/update'%server.server_port
prepare('interrupted-download','failed');server.shutdown()
base['asset']['url']=image.as_uri();prepare('interrupted-download-retry','readyToApply')
out=repo/'Tests/out/update-failures';out.mkdir(exist_ok=True)
for p in work.glob('*.json'):shutil.copy2(p,out/p.name)
print('All updater helper failure/recovery checks passed; evidence:',out)
