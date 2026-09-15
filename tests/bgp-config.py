#!/usr/bin/env python3
"""Router generation and discovery guards; no router or Kubernetes writes."""
import importlib.util
import json
from pathlib import Path
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bgp_setup', ROOT / 'scripts/configure-bgp.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)
settings = yaml.safe_load((ROOT / 'clusters/base/defaults.yaml').read_text())['data']
settings.update(yaml.safe_load((ROOT / 'clusters/laptops/settings.yaml').read_text())['data'])
settings.update(API_HOST='192.168.2.153', BGP_ROUTER_IP='192.168.2.1', LAN_CIDR='192.168.2.0/24',
                DNS_CLIENT_CIDR='192.168.2.0/24', BGP_PEER_ASN='64512', BGP_LOCAL_ASN='64513')


def rejects(function, *args, **kwargs):
    try:
        function(*args, **kwargs)
    except (ValueError, AssertionError):
        return
    raise AssertionError('Unsafe router configuration accepted')


ips = ['192.168.2.155', '192.168.2.153', '192.168.2.154']
config = setup.router_config(settings, ips)
assert config == setup.router_config(settings, list(reversed(ips)))
commands = [line for line in config.splitlines() if not line.startswith('#')]
assert commands[0] == 'configure' and commands[-1] == 'compare'
assert not any(line in ('commit', 'save', 'exit') or line.startswith('delete ') for line in commands)
permits = [line for line in commands if ' prefix ' in line and '-IN ' in line]
assert {line.split()[-1] for line in permits} == {settings['EDGE_IP'] + '/32', settings['DNS_IP'] + '/32'}
assert len(permits) == 2
assert 'set policy prefix-list ELEKTRO-LAPTOPS-OUT rule 10 action deny' in commands
assert 'set policy prefix-list ELEKTRO-LAPTOPS-OUT rule 10 le 32' in commands
assert not any('redistribute' in line or ' network ' in line or 'multihop' in line for line in commands)
assert {line.split()[5] for line in commands if ' neighbor ' in line} == set(ips)
assert sum(line.endswith('maximum-prefix 2') for line in commands) == 3
assert 'parameters router-id' not in config
assert 'set protocols bgp 64512 parameters router-id 192.168.2.1' in setup.router_config(
    settings, ips, router_id='192.168.2.1')
for router_id in ('0.0.0.0', '224.0.0.1', '255.255.255.255', '::1', '192.168.2.1; commit'):
    rejects(setup.router_config, settings, ips, router_id=router_id)
assert 'service dns forwarding' not in config
assert f"server=/internal/{settings['DNS_IP']}" in setup.router_config(settings, ips, True)
restricted_dns = {**settings, 'DNS_CLIENT_CIDR': '192.168.2.128/25'}
assert setup.router_config(restricted_dns, ips)
rejects(setup.router_config, restricted_dns, ips, dns_forwarding=True)
public = {**settings, 'PUBLIC_EDGE_IP': '10.44.0.241', 'IDENTITY_HOST': 'login.example.org'}
assert '10.44.0.241/32' not in setup.router_config(public, ips)
public_config = setup.router_config(public, ips, include_public=True)
assert 'set policy prefix-list ELEKTRO-LAPTOPS-IN rule 30 prefix 10.44.0.241/32' in public_config
assert public_config.count('maximum-prefix 3') == len(ips)
assert public_config.count(' action permit') == 3
rejects(setup.router_config, settings, ips, include_public=True)
rejects(setup.router_config, {**settings, 'PUBLIC_EDGE_IP': '10.44.0.241'}, ips, include_public=True)
rejects(setup.router_config, {**settings, 'IDENTITY_HOST': 'login.example.org'}, ips, include_public=True)
for addresses in ([], [ips[0], ips[0]], ['192.168.2.1'], ['192.168.3.10'],
                  ['192.168.2.0'], ['192.168.2.255'], ['127.0.0.1'], ['2001:db8::1'],
                  ['192.168.2.153; commit']):
    rejects(setup.router_config, settings, addresses)
rejects(setup.router_config, {**settings, 'API_VIP': '192.168.2.10', 'API_VIP_INTERFACE': 'eth0'}, ['192.168.2.10'])


def kube_response(*args):
    if args[:2] == ('config', 'view'):
        return json.dumps({'clusters': [{'cluster': {'server': 'https://192.168.2.153:6443'}}]})
    if args[:4] == ('-n', 'flux-system', 'get', 'configmap'):
        return json.dumps({'data': {'CLUSTER_NAME': 'laptops'}})
    assert args == ('get', 'nodes', '-l', 'node-role.kubernetes.io/control-plane', '-o', 'json')
    return json.dumps({'items': [{'metadata': {'name': 'server'}, 'status': {'addresses': [
        {'type': 'ExternalIP', 'address': '203.0.113.5'},
        {'type': 'InternalIP', 'address': '2001:db8::1'},
        {'type': 'InternalIP', 'address': '192.168.2.153'}]}}]})


with patch.object(setup, 'kubectl', side_effect=kube_response):
    assert setup.discover_nodes(settings) == ['192.168.2.153']
with patch.object(setup, 'kubectl', return_value=json.dumps({'clusters': [{'cluster': {'server': 'https://wrong:6443'}}]})) as fake:
    rejects(setup.discover_nodes, settings)
    assert fake.call_count == 1  # Stop before querying another cluster.
with patch.object(setup, 'kubectl', side_effect=[kube_response('config', 'view'), json.dumps({'data': {'CLUSTER_NAME': 'other'}})]) as fake:
    rejects(setup.discover_nodes, settings)
    assert fake.call_count == 2
with patch.object(setup, 'kubectl', side_effect=[kube_response('config', 'view'), '', '{"items": []}']):
    rejects(setup.router_config, settings, setup.discover_nodes(settings))
with patch.object(setup, 'kubectl', side_effect=[kube_response('config', 'view'), '', json.dumps({'items': [{'metadata': {'name': 'no-ip'}}]})]):
    rejects(setup.discover_nodes, settings)
print('Exact router filters, stable peers, deterministic output, injection rejection and discovery guards passed.')
