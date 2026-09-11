#!/usr/bin/env python3
"""Check rendered integration and run the upstream metrics stack in disposable CI."""
import argparse
import configparser
import json
import pathlib
import subprocess
import time
import urllib.error
import urllib.request

import yaml

from render import read, profile_settings

ROOT = pathlib.Path(__file__).resolve().parents[1]


def check_rendered():
    objects = read(ROOT / 'rendered/charts/metrics.yaml')
    settings = profile_settings()
    by_key = {(o['kind'], o['metadata']['name']): o for o in objects}
    prometheus = by_key['Prometheus', 'metrics-prometheus']['spec']
    for kind in ['serviceMonitor', 'podMonitor', 'rule', 'probe', 'scrapeConfig']:
        assert prometheus[kind + 'NamespaceSelector'] == {
            'matchLabels': {'kubernetes.io/metadata.name': 'monitoring'}}
        assert prometheus[kind + 'Selector']['matchLabels'] == {'release': 'metrics'}
    assert prometheus['arbitraryFSAccessThroughSMs'] == {'deny': True}
    assert prometheus['externalLabels']['cluster'] == settings['CLUSTER_NAME']
    assert prometheus['retention'] == '7d' and prometheus['retentionSize'] == '15GB'
    for o in objects:
        if o['kind'] == 'Service':
            assert o['spec'].get('type', 'ClusterIP') == 'ClusterIP'
            assert not o['spec'].get('externalIPs')
        if o['kind'] in ['DaemonSet', 'Deployment']:
            pod = o['spec']['template']['spec']
            assert not pod.get('hostNetwork'), o['metadata']['name']
            for c in pod['containers']:
                assert all(not p.get('hostPort') for p in c.get('ports', []))
        if o['kind'] == 'ClusterRoleBinding':
            assert all(s.get('name') != 'grafana' for s in o.get('subjects', []))
    grafana = by_key['Deployment', 'grafana']['spec']['template']['spec']
    main = next(c for c in grafana['containers'] if c['name'] == 'grafana')
    assert {'name': 'GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION', 'value': 'true'} in main['env']
    assert not any(e['name'].startswith('GF_SECURITY_ADMIN_') for e in main['env'])
    sidecar = next(c for c in grafana['containers'] if 'sidecar' in c['image'])
    env = {e['name']: e.get('value') for e in sidecar['env']}
    assert env['NAMESPACE'] == 'monitoring' and env['RESOURCE'] == 'configmap'
    assert not env.get('REQ_URL'), 'Do not call password-protected provisioning APIs'
    config = configparser.ConfigParser(interpolation=None)
    config.read_string(by_key['ConfigMap', 'grafana']['data']['grafana.ini'])
    assert config['auth.proxy']['header_name'] == 'X-Elektro-Subject'
    assert config['auth.proxy']['whitelist'] == settings['POD_CIDR']
    assert not config.getboolean('auth.proxy', 'enable_login_token')
    assert not config.getboolean('auth.anonymous', 'enabled')
    assert not config.getboolean('auth.basic', 'enabled')
    assert config['users']['auto_assign_org_role'] == 'Viewer'
    print('Rendered metrics: private Services, trusted configuration discovery and proxy authentication verified.')


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def request(port, path, headers=None):
    try:
        with urllib.request.urlopen(urllib.request.Request(
                f'http://127.0.0.1:{port}{path}', headers=headers or {}), timeout=10) as r:
            return r.status, json.load(r), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers


def runtime():
    context = subprocess.check_output(['kubectl', 'config', 'current-context'], text=True).strip()
    assert context == 'kind-elektro-validation', context
    run('kubectl', 'label', 'node', '--all', 'elektro.local/workloads=true', '--overwrite')
    run('helm', 'upgrade', '--install', 'cert-manager', '.cache/charts/cert-manager/cert-manager',
        '-n', 'cert-manager', '-f', '.cache/values/cert-manager.yaml', '--wait', '--timeout', '5m', '--take-ownership')
    values = yaml.safe_load((ROOT / '.cache/values/metrics.yaml').read_text())
    # CI has no Longhorn or production gateway. Only replace persistent volumes
    # with emptyDir and trust the local port-forward for auth-proxy API probes.
    values['prometheus']['prometheusSpec']['storageSpec'] = None
    values['alertmanager']['alertmanagerSpec']['storage'] = None
    values['grafana']['persistence']['enabled'] = False
    values['grafana']['grafana.ini']['auth.proxy']['whitelist'] = '127.0.0.1/32'
    (ROOT / '.cache/metrics-runtime-values.yaml').write_text(yaml.safe_dump(values))
    run('helm', 'upgrade', '--install', 'metrics', '.cache/charts/metrics/kube-prometheus-stack',
        '-n', 'monitoring', '-f', '.cache/metrics-runtime-values.yaml', '--wait', '--timeout', '8m', '--take-ownership')
    # Helm's CR creation does not imply that operator-managed StatefulSets are ready.
    for name in ['prometheus-metrics-prometheus', 'alertmanager-metrics-alertmanager']:
        for _ in range(60):
            result = subprocess.run(['kubectl', '-n', 'monitoring', 'get', 'statefulset', name],
                                    capture_output=True)
            if result.returncode == 0:
                break
            time.sleep(2)
        run('kubectl', '-n', 'monitoring', 'rollout', 'status', 'statefulset/' + name, '--timeout=3m')
    run('kubectl', 'apply', '--server-side', '--field-manager=elektro-validation',
        '-f', 'rendered/infrastructure-monitoring-config.yaml')
    forwards = []
    try:
        for service, local, remote in [('grafana', 13000, 80), ('metrics-prometheus', 19090, 9090)]:
            forwards.append(subprocess.Popen(['kubectl', '-n', 'monitoring', 'port-forward',
                                              'service/' + service, f'{local}:{remote}'],
                                             stdout=subprocess.DEVNULL))
        for _ in range(60):
            try:
                if request(13000, '/api/health')[0] == 200:
                    break
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(1)
        assert request(13000, '/api/user')[0] == 401
        assert request(13000, '/api/datasources')[0] == 401
        verified = {'X-Elektro-Subject': '11111111-1111-4111-8111-111111111111',
                    'X-WEBAUTH-USER': 'admin', 'X-WEBAUTH-ROLE': 'Admin',
                    'X-Forwarded-For': '192.168.50.99'}
        status, user, headers = request(13000, '/api/user', verified)
        assert status == 200 and user['login'] == verified['X-Elektro-Subject'], user
        assert user['isGrafanaAdmin'] is False, user
        status, orgs, _ = request(13000, '/api/user/orgs', verified)
        assert status == 200 and len(orgs) == 1 and orgs[0]['role'] == 'Viewer', orgs
        assert not any('grafana_session=' in h for h in headers.get_all('Set-Cookie', []))
        assert request(13000, '/api/user')[0] == 401, 'A previous proxy login must not enable anonymous access'
        status, sources, _ = request(13000, '/api/datasources', verified)
        assert status == 200 and {s['uid'] for s in sources} == {'prometheus', 'alertmanager'}, sources
        # Real ingestion and provisioned dashboards, not just a Ready process.
        for _ in range(90):
            status, data, _ = request(19090, '/api/v1/query?query=up')
            samples = data.get('data', {}).get('result', []) if isinstance(data, dict) else []
            jobs = {s['metric'].get('job') for s in samples if s['value'][1] == '1'}
            dashboards = request(13000, '/api/search?type=dash-db', verified)[1]
            if {'node-exporter', 'kubelet'} <= jobs and isinstance(dashboards, list) and len(dashboards) > 5:
                break
            time.sleep(2)
        assert {'node-exporter', 'kubelet'} <= jobs, jobs
        assert isinstance(dashboards, list) and len(dashboards) > 5, dashboards
        assert request(13000, '/api/datasources/proxy/uid/prometheus/api/v1/query?query=up', verified)[0] == 200
        print('Upstream metrics stack is Ready; real node/kubelet samples, dashboards and Grafana auth/role checks passed.')
    finally:
        for process in forwards:
            process.terminate()
            process.wait(timeout=10)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', action='store_true')
    args = parser.parse_args()
    check_rendered()
    if args.runtime:
        runtime()
