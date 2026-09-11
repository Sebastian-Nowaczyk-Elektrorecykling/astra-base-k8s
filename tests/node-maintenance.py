#!/usr/bin/env python3
"""Failure-path tests with isolated fake API/SSH boundaries. Never contacts a cluster or host."""
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
PIN = 'v1.36.4+k3s1'
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['CASE'])
s=json.loads((p/'cluster.json').read_text())
a=sys.argv[1:]
command=pathlib.Path(sys.argv[0]).name
with (p/'calls.log').open('a') as f: f.write(json.dumps([command]+a)+'\n')
def save(): (p/'cluster.json').write_text(json.dumps(s))
def out(value): print(json.dumps(value) if not isinstance(value,str) else value)
def err(message): print(message,file=sys.stderr); sys.exit(1)
if command=='ssh':
    sys.stdin.read()
    match=__import__('re').search(r"exec bash -s -- '([^']+)'",a[-1]); op=match[1]
    if s.get('ssh_failure')==op: err('simulated host failure')
    if op=='stop': s['stopped']=True
    if op=='uninstall':
        assert s.get('stopped') and not s.get('target_exists',True)
        s['uninstalled']=True
    save(); sys.exit(0)
if command=='getent':
    host=a[-1]
    out(('192.0.2.12' if host=='target.example' else host)+' STREAM')
    sys.exit(0)
a=[x for x in a if not x.startswith('--request-timeout=')]
namespace=None
if '-n' in a:
    i=a.index('-n'); namespace=a[i+1]; del a[i:i+2]
def listof(items): out({'items':items})
if a[:3]==['config','view','--minify']: out('https://'+s.get('api_host','192.0.2.10')+':6443')
elif a[0]=='get' and '--raw=/readyz' in a: out('ok')
elif a[:2]==['get','namespace']: out(s.get('cluster_uid','cluster-a'))
elif a[:2]==['get','nodes']: listof(s['nodes'])
elif a[:2]==['get','node']:
    if not s.get('target_exists',True):
        if '--ignore-not-found' in a: sys.exit(0)
        err('node not found')
    out(s['nodes'][0])
elif a[:2]==['get','persistentvolumes']: listof(s.get('pvs',[]))
elif a[:2]==['get','crd']:
    if s.get('crd_error'): err('forbidden')
    if s.get('longhorn'): out('customresourcedefinition.apiextensions.k8s.io/nodes.longhorn.io')
elif a[:2]==['get','configmap']: out({'data':{'API_HOST':s.get('api_host','192.0.2.10')}})
elif a[:2]==['get','daemonset']: pass
elif a[:2]==['get','replicas.longhorn.io']: listof(s.get('replicas',[]))
elif a[:2]==['get','volumes.longhorn.io']: listof(s.get('volumes',[]))
elif a[:2]==['get','nodes.longhorn.io']:
    if '-o' in a and a[a.index('-o')+1]=='name': out('nodes.longhorn.io/k8s2')
    else: out(s.get('lh_node',{'status':{'diskStatus':{}}}))
elif a[:2]==['get','volumeattachments.storage.k8s.io']: listof(s.get('attachments',[]))
elif a[:2]==['get','secret']: pass
elif a[:2]==['get','pods']: listof([])
elif a[0]=='cordon': s['nodes'][0]['spec']['unschedulable']=True; save()
elif a[0]=='uncordon': s['nodes'][0]['spec']['unschedulable']=False; save()
elif a[0]=='drain':
    if s.get('pdb_blocked'): err('Cannot evict pod as it would violate the pod disruption budget.')
    assert '--force' not in a and '--disable-eviction' not in a
elif a[0]=='patch': pass
elif a[0]=='annotate':
    if not s.get('member_stuck'):
        annotations=s['nodes'][0]['metadata']['annotations']
        annotations['etcd.k3s.cattle.io/removed-node-name']=annotations['etcd.k3s.cattle.io/node-name']
    save()
elif a[0]=='delete' and a[1]=='node':
    assert s.get('stopped')
    if s['nodes'][0]['metadata']['labels']['elektro.local/role']!='worker':
        assert s['nodes'][0]['metadata']['annotations'].get('etcd.k3s.cattle.io/removed-node-name')
    s['target_exists']=False; save()
elif a[0]=='delete' and a[1]=='nodes.longhorn.io': assert s.get('uninstalled')
elif a[0]=='label':
    for label in a[3:]:
        if '=' in label and not label.startswith('--'):
            k,v=label.split('=',1); s['nodes'][0]['metadata']['labels'][k]=v
    save()
elif a[0]=='taint': pass
else: err('Unexpected fake API command: '+repr(a))
'''


def node(name, role, ip):
    labels={'elektro.local/role':role,'elektro.local/workloads':'false' if role=='controller' else 'true'}
    if role!='worker': labels.update({'node-role.kubernetes.io/etcd':'true','node-role.kubernetes.io/control-plane':'true'})
    return {'metadata':{'name':name,'uid':name+'-uid','labels':labels,
                        'annotations':{'etcd.k3s.cattle.io/node-name':name+'-etcd'}},'spec':{},
            'status':{'nodeInfo':{'machineID':'123abc','kubeletVersion':PIN},
                      'addresses':[{'type':'InternalIP','address':ip}],
                      'conditions':[{'type':'Ready','status':'True'}]}}


def fixture(role='worker', servers=1):
    nodes=[node('k8s2',role,'192.0.2.12'),node('k8s1','hybrid','192.0.2.10')]
    if role!='worker' and servers==1: nodes[1]=node('k8s1','worker','192.0.2.10')
    if servers==3: nodes.append(node('k8s3','hybrid','192.0.2.13'))
    return {'nodes':nodes,'longhorn':False}


def storage_fixture():
    s=fixture()
    s.update(longhorn=True,replicas=[{'metadata':{'name':'replica-a'},'spec':{'nodeID':'k8s1','volumeName':'data','healthyAt':'2026-01-01','failedAt':'','active':True}}],
             volumes=[{'metadata':{'name':'data'},'spec':{'numberOfReplicas':1,'nodeID':''},'status':{'robustness':'healthy','currentNodeID':''}}])
    return s


def run_case(name, cluster, *, apply=True, script='remove-node.sh', extra=(), expect=0, reason=None, resume_failure=None):
    with tempfile.TemporaryDirectory(prefix='elektro-maintenance-test-', dir=ROOT.parent) as tmp:
        t=pathlib.Path(tmp); repo=t/'repo'; repo.mkdir()
        shutil.copytree(ROOT/'scripts',repo/'scripts')
        shutil.copytree(ROOT/'bootstrap',repo/'bootstrap')
        (t/'cluster.json').write_text(json.dumps(cluster))
        bins=t/'bin'; bins.mkdir()
        for command in ['kubectl','ssh','getent']:
            p=bins/command; p.write_text(FAKE); p.chmod(0o755)
        sleeper=bins/'sleep'; sleeper.write_text('#!/bin/sh\nexec /bin/sleep 0.1\n'); sleeper.chmod(0o755)
        env=dict(os.environ,CASE=str(t),PATH=str(bins)+':'+os.environ['PATH'])
        args=['bash',str(repo/'scripts'/script),'--node','k8s2','--ssh','root@target.example','--timeout','1']
        if apply: args+=['--apply']
        result=subprocess.run(args+list(extra),env=env,text=True,capture_output=True,timeout=25)
        assert (result.returncode==0)==(expect==0),(name,result.stdout,result.stderr)
        if reason: assert reason in result.stderr,(name,result.stderr)
        calls=[json.loads(line) for line in (t/'calls.log').read_text().splitlines()]
        operations=[re.search(r"exec bash -s -- '([^']+)'",c[-1])[1] for c in calls if c[0]=='ssh']
        if not apply:
            assert operations==['inspect'],(name,operations)
            assert not any(c[0]=='kubectl' and any(x in c for x in ['cordon','drain','patch','delete','annotate','label','taint']) for c in calls)
            assert not (repo/'local').exists()
        if expect and script=='remove-node.sh' and not resume_failure:
            assert 'uninstall' not in operations and 'stop' not in operations,(name,operations)
        if expect==0 and apply and script=='remove-node.sh':
            assert operations[-3:]==['stop','stopped','uninstall'],(name,operations)
            state=next((repo/'local/node-maintenance').glob('*.json'))
            assert json.loads(state.read_text())['phase']=='complete'
        if script=='set-server-role.sh' and expect==0:
            assert 'stop' not in operations and 'uninstall' not in operations
        if resume_failure:
            state=next((repo/'local/node-maintenance').glob('*.json'))
            updated=json.loads((t/'cluster.json').read_text())
            updated.pop(resume_failure)
            (t/'cluster.json').write_text(json.dumps(updated))
            second=subprocess.run(args+['--resume',str(state)],env=env,text=True,capture_output=True,timeout=25)
            assert second.returncode==0,(name,second.stdout,second.stderr)
            assert json.loads(state.read_text())['phase']=='complete'
            # The same state must not be applied to a replacement Node using the old name.
            updated=json.loads((t/'cluster.json').read_text())
            updated['target_exists']=True
            updated['nodes'][0]['metadata']['uid']='replacement-uid'
            (t/'cluster.json').write_text(json.dumps(updated))
            third=subprocess.run(args+['--resume',str(state)],env=env,text=True,capture_output=True,timeout=25)
            assert third.returncode!=0 and 'replaced/rejoined' in third.stderr
        print('Passed:',name)


run_case('read-only worker plan',fixture(),apply=False)
run_case('worker removal completes in safe order',fixture())
run_case('last server cannot be removed',fixture('hybrid',1),expect=1,reason='last server')
run_case('two-server removal retires etcd before stopping',fixture('hybrid',2))
run_case('three-server removal',fixture('controller',3))
s=fixture('hybrid',2);s['api_host']='192.0.2.12'
run_case('target API address is rejected',s,expect=1,reason='still points at')
s=fixture();s['nodes'][1]['metadata']['labels']['elektro.local/workloads']='false'
run_case('last workload capacity is protected',s,expect=1,reason='workload-capable')
s=fixture();s['crd_error']=True
run_case('API failure cannot masquerade as absent Longhorn',s,expect=1,reason='whether Longhorn')
s=fixture();s['pdb_blocked']=True
run_case('PDB failure prevents host shutdown',s,expect=1,reason='disruption budget')
s=fixture('hybrid',2);s['member_stuck']=True
run_case('unacknowledged etcd retirement prevents shutdown',s,expect=1,reason='acknowledge')
s=storage_fixture();s['replicas'][0]['spec']['nodeID']='k8s2'
run_case('last Longhorn copy prevents shutdown',s,expect=1,reason='Longhorn replicas')
s=fixture();s['attachments']=[{'spec':{'nodeName':'k8s2'}}]
run_case('remaining CSI attachment prevents shutdown',s,expect=1,reason='CSI volumes')
run_case('sole server can become dedicated',fixture('hybrid',1),script='set-server-role.sh',extra=['--role','controller'])
run_case('dedicated server can become hybrid',fixture('controller',1),script='set-server-role.sh',extra=['--role','hybrid'])
run_case('worker cannot become server by changing labels',fixture(),script='set-server-role.sh',extra=['--role','hybrid'],expect=1,reason='removed and rejoined')

s=fixture();s['ssh_failure']='uninstall'
run_case('resume after node deletion, reject replacement UID',s,expect=1,reason='simulated host failure',resume_failure='ssh_failure')
s=fixture();s['pdb_blocked']=True
run_case('resume after resolving a blocked drain',s,expect=1,reason='disruption budget',resume_failure='pdb_blocked')

# Exercise the actual storage gate with copies that must not count as safe replacements.
with tempfile.TemporaryDirectory(dir=ROOT.parent) as tmp:
    t=pathlib.Path(tmp); (t/'cluster.json').write_text(json.dumps(storage_fixture()))
    fake=t/'kubectl';fake.write_text(FAKE);fake.chmod(0o755)
    command='source "$REPO/scripts/lib/node-maintenance.sh"; node=k8s2; affected=\'["data"]\'; storage_evacuated'
    env=dict(os.environ,CASE=str(t),REPO=str(ROOT),PATH=str(t)+':'+os.environ['PATH'])
    for property_,value in [('healthyAt',''),('failedAt','2026-02-01'),('active',False),('nodeID','')]:
        s=storage_fixture();s['replicas'][0]['spec'][property_]=value;(t/'cluster.json').write_text(json.dumps(s))
        assert subprocess.run(['bash','-c',command],env=env).returncode!=0,property_
    s=storage_fixture();s['volumes'][0]['spec']['numberOfReplicas']=3;(t/'cluster.json').write_text(json.dumps(s))
    assert subprocess.run(['bash','-c',command],env=env).returncode!=0
    (t/'cluster.json').write_text(json.dumps(storage_fixture()))
    assert subprocess.run(['bash','-c',command],env=env).returncode==0
print('Passed: rebuilding, failed, inactive, unassigned and insufficient replicas are rejected')

# Execute the same awk program shipped to the host, checking unrelated settings and taints survive a round trip.
source=(ROOT/'scripts/lib/node-host.sh').read_text()
program=re.search(r"awk -v role=\"\$operation\" '(.*?)' \"\$cfg\"",source,re.S)[1]
config='''node-name: "k8s2"
node-label:
  - "elektro.local/role=hybrid"
  - "elektro.local/workloads=true"
  - "node.longhorn.io/create-default-disk=true"
  - "custom.example/team=data"
node-taint:
  - "custom.example/reserved=true:NoSchedule"
cluster-cidr: "10.42.0.0/16"
tls-san:
  - "api.hosts.internal"
'''
for role in ['controller','hybrid','controller']:
    config=subprocess.check_output(['awk','-v','role='+role,program],input=config,text=True)
    parsed=yaml.safe_load(config)
    assert 'elektro.local/role='+role in parsed['node-label']
    assert 'custom.example/team=data' in parsed['node-label']
    assert 'custom.example/reserved=true:NoSchedule' in parsed['node-taint']
    assert ('elektro.local/dedicated=control-plane:NoSchedule' in parsed['node-taint'])==(role=='controller')
    assert parsed['cluster-cidr']=='10.42.0.0/16' and parsed['tls-san']==['api.hosts.internal']
print('Passed: durable role changes preserve unrelated labels, taints, CIDRs and API SANs')
