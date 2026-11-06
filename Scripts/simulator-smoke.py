import subprocess,json,time,pathlib
def run(*args):return subprocess.check_output(args,text=True).strip()
devices=json.loads(run('xcrun','simctl','list','devices','available','--json'))['devices']
phones=[d for group in devices.values() for d in group if 'iPhone' in d['name']]
d=next((d for d in phones if 'Pro Max' in d['name']),phones[0]);udid=d['udid']
subprocess.run(['xcrun','simctl','boot',udid],check=False)
subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],check=True)
run('xcrun','simctl','install',udid,'build-sim/Build/Products/Release-iphonesimulator/PhotoDenoise.app')
out=pathlib.Path('smoke-output');out.mkdir(exist_ok=True)
container=pathlib.Path(run('xcrun','simctl','get_app_container',udid,'io.alpha1m2.photodenoise','data'))
status=container/'Documents/smoke-status.json'
for mode in ['rgb','raw','lens']:
    subprocess.run(['xcrun','simctl','terminate',udid,'io.alpha1m2.photodenoise'],check=False)
    status.unlink(missing_ok=True)
    run('xcrun','simctl','launch',udid,'io.alpha1m2.photodenoise','--smoke-'+mode)
    deadline=time.time()+240
    while not status.exists() and time.time()<deadline:time.sleep(2)
    if not status.exists():raise RuntimeError(mode+' simulator inference timed out')
    report=json.loads(status.read_text());(out/(mode+'.json')).write_text(json.dumps(report,ensure_ascii=False))
    time.sleep(2)
    run('xcrun','simctl','io',udid,'screenshot',str(out/(mode+'.png')))
    assert report['ok'],report
print('Simulator inference passed for RAW and JPEG on',d['name'])
