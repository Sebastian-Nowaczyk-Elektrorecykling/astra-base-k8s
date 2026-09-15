#!/usr/bin/env python3
"""Catch LAN/pool mistakes before bootstrap and bound BGP-only exposure."""
import importlib.util
import ipaddress
from pathlib import Path
import re

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('settings', ROOT / 'scripts/validate-cluster.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
settings = yaml.safe_load((ROOT / 'clusters/base/defaults.yaml').read_text())['data']
settings.update(yaml.safe_load((ROOT / 'clusters/laptops/settings.yaml').read_text())['data'])
module.validate(settings)
# Exercise rejection cases independently of future profile address edits.
settings.update(LAN_CIDR='192.168.2.0/24', DNS_CLIENT_CIDR='192.168.2.0/24',
                API_HOST='192.168.2.153', LB_CIDR='10.44.0.0/24',
                LB_START='10.44.0.240', LB_STOP='10.44.0.249',
                EDGE_IP='10.44.0.240', DNS_IP='10.44.0.242',
                POD_CIDR='10.42.0.0/16', SERVICE_CIDR='10.43.0.0/16', CLUSTER_DNS='10.43.0.10',
                DNS_UPSTREAMS='1.1.1.1 9.9.9.9', PUBLIC_EDGE_IP='NOT_CONFIGURED',
                BGP_ROUTER_IP='192.168.2.1', BGP_LOCAL_ASN='64513', BGP_PEER_ASN='64512')


def rejected(**overrides):
    try:
        module.validate({**settings, **overrides})
    except (AssertionError, ValueError):
        return
    raise AssertionError(f'Unsafe configuration accepted: {overrides}')


# LAN changes do not require moving an already disjoint routed service subnet.
for subnet in (0, 1, 2, 50, 255):
    prefix = f'192.168.{subnet}'
    module.validate({**settings, 'LAN_CIDR': prefix + '.0/24',
                     'DNS_CLIENT_CIDR': prefix + '.0/24', 'API_HOST': prefix + '.153',
                     'BGP_ROUTER_IP': prefix + '.1'})
module.validate({**settings, 'LAN_CIDR': '192.168.2.0/23', 'DNS_CLIENT_CIDR': '192.168.2.0/23'})
module.validate({**settings, 'LAN_CIDR': '192.168.0.0/16', 'DNS_CLIENT_CIDR': '192.168.0.0/16'})
for cidr in ('192.168.2.0/24', '10.42.0.0/16', '10.43.0.0/16', '0.0.0.0/0', '203.0.113.0/24'):
    rejected(LB_CIDR=cidr)
rejected(LB_CIDR='192.168.3.0/24', DNS_CLIENT_CIDR='192.168.2.0/23')
rejected(LB_CIDR='10.44.0.0/31')
rejected(LB_CIDR='10.44.0.1/24')
rejected(LB_START='10.44.0.0')
rejected(LB_STOP='10.44.0.255')
rejected(LB_STOP='10.44.1.1')
rejected(LB_START='10.44.0.250')
rejected(EDGE_IP='192.168.2.240')
rejected(DNS_IP=settings['EDGE_IP'])
rejected(PUBLIC_EDGE_IP=settings['DNS_IP'])
rejected(API_HOST='10.44.0.245')
rejected(API_HOST='10.44.0.10')  # Even outside the allocated portion of LB_CIDR.
rejected(API_HOST='999.168.2.153')
rejected(API_HOST='127.0.0.1')
rejected(API_HOST='0.0.0.0')
rejected(API_VIP='10.44.0.245', API_VIP_INTERFACE='eth0')
rejected(API_VIP='192.168.2.10')
rejected(API_VIP=settings['BGP_ROUTER_IP'], API_VIP_INTERFACE='eth0')
rejected(API_VIP_INTERFACE='eth0')
module.validate({**settings, 'API_VIP': '192.168.2.10', 'API_VIP_INTERFACE': 'eth0'})
rejected(POD_CIDR='192.168.0.0/16')
rejected(SERVICE_CIDR='192.168.2.0/24', CLUSTER_DNS='192.168.2.10')
rejected(BGP_ENABLED='false')
rejected(BGP_ENABLED='true')
rejected(LAN_INTERFACE_REGEX='eth.*')
for router in ('NOT_CONFIGURED', '192.168.50.1', '192.168.2.0', '192.168.2.255', '192.168.2.153'):
    rejected(BGP_ROUTER_IP=router)
rejected(BGP_PEER_ASN='64513')
rejected(BGP_PEER_ASN='123')
module.validate({**settings, 'PUBLIC_EDGE_IP': '10.44.0.241'})

bgp = list(yaml.safe_load_all((ROOT / 'infrastructure/bgp/resources.yaml').read_text()))
config, peer, advertisement = bgp
assert config['spec']['nodeSelector'] == {'matchExpressions': [
    {'key': 'node-role.kubernetes.io/control-plane', 'operator': 'Exists'}]}
assert 'localPort' not in config['spec']['bgpInstances'][0]
rules = advertisement['spec']['advertisements']
assert len(rules) == 2
assert all(r['attributes']['communities']['wellKnown'] == ['no-advertise'] for r in rules)
assert all(r['advertisementType'] == 'Service' and r['service']['addresses'] == ['LoadBalancerIP'] for r in rules)


def advertised(namespace, name, **labels):
    labels.update({'io.kubernetes.service.namespace': namespace, 'io.kubernetes.service.name': name})
    return any(all(labels.get(k) == v for k, v in r['selector']['matchLabels'].items()) for r in rules)


assert advertised('kube-system', 'lan-dns')
assert advertised('envoy-gateway-system', 'envoy-any-generated-name', **{
    'gateway.envoyproxy.io/owning-gateway-namespace': 'edge',
    'gateway.envoyproxy.io/owning-gateway-name': 'platform'})
assert not advertised('envoy-gateway-system', 'envoy-public', **{
    'gateway.envoyproxy.io/owning-gateway-namespace': 'edge',
    'gateway.envoyproxy.io/owning-gateway-name': 'public'})
assert not advertised('kube-system', 'kube-dns')
assert not advertised('app-demo', 'lan-dns')
assert not advertised('monitoring', 'grafana')

# The peer accepts the separately attached public advertisement, without adding
# it to the base or letting its selector match another gateway/DNS Service.
public = yaml.safe_load((ROOT / 'examples/public-exposure/bgp/resources.yaml').read_text())
selected = peer['spec']['families'][0]['advertisements']['matchLabels']
for obj in (advertisement, public):
    assert all(obj['metadata']['labels'].get(k) == v for k, v in selected.items())
public_rules = public['spec']['advertisements']
assert len(public_rules) == 1
assert public_rules[0]['selector'] == {'matchLabels': {
    'io.kubernetes.service.namespace': 'envoy-gateway-system',
    'gateway.envoyproxy.io/owning-gateway-namespace': 'edge',
    'gateway.envoyproxy.io/owning-gateway-name': 'public'}}
assert public_rules[0]['attributes']['communities']['wellKnown'] == ['no-advertise']
assert public_rules[0]['service']['addresses'] == ['LoadBalancerIP']
public_stage = next(obj for obj in yaml.safe_load_all((ROOT / 'examples/public-exposure/reconciliation.yaml').read_text())
                    if obj['metadata']['name'] == 'public-bgp')
assert {d['name'] for d in public_stage['spec']['dependsOn']} == {'bgp', 'public-edge'}
assert public_stage['spec']['prune'] is True and public_stage['spec']['wait'] is False
assert not any('public-exposure' in p.read_text() or 'api-vip' in p.read_text()
               for p in (ROOT / 'clusters/base').rglob('*.yaml'))

# Validate the actual documented same-LAN profiles, including cross-cluster
# address overlap, so on-link/DHCP examples cannot silently return.
section = (ROOT / 'docs/clusters.md').read_text().split('## Two clusters on the same LAN')[1]
examples = [dict(settings), {**settings, 'CLUSTER_NAME': 'production',
                           'INTERNAL_DOMAIN': 'production.internal',
                           'IDENTITY_HOST': 'keycloak.admin.production.internal'}]
for line in section.splitlines():
    if not line.startswith('| `'):
        continue
    columns = line.split('|')[1:-1]
    keys = re.findall(r'`([A-Z_]+)`', columns[0])
    for example, column in zip(examples, columns[1:]):
        values = re.findall(r'`([^`]+)`', column)
        if len(values) == 1:
            values *= len(keys)
        assert len(keys) == len(values)
        example.update(zip(keys, values))
for example in examples:
    module.validate(example)
networks = [ipaddress.IPv4Network(e[key]) for e in examples
            for key in ('LB_CIDR', 'POD_CIDR', 'SERVICE_CIDR')]
assert all(not left.overlaps(right) for i, left in enumerate(networks) for right in networks[i + 1:])
assert examples[0]['BGP_LOCAL_ASN'] != examples[1]['BGP_LOCAL_ASN']

# Controller peers may forward to backends on workers; preserve Cluster/SNAT.
cilium = yaml.safe_load((ROOT / 'infrastructure/cilium/values.yaml').read_text())
assert cilium['kubeProxyReplacement'] is True
assert cilium['l2announcements']['enabled'] is False
assert cilium['l2podAnnouncements']['enabled'] is False
assert cilium['bgpControlPlane']['enabled'] is True
assert cilium['rollOutCiliumPods'] and cilium['operator']['rollOutPods']
assert yaml.safe_load((ROOT / 'infrastructure/cilium/kustomization.yaml').read_text())['generatorOptions']['labels']['reconcile.fluxcd.io/watch'] == 'Enabled'
assert not any(obj.get('kind') == 'CiliumL2AnnouncementPolicy'
               for p in (ROOT / 'infrastructure').rglob('*.yaml')
               for obj in yaml.safe_load_all(p.read_text()) if obj)
assert cilium['routingMode'] == 'tunnel' and cilium['tunnelProtocol'] == 'vxlan'
assert cilium['loadBalancer']['mode'] == 'snat'
dns = next(obj for obj in yaml.safe_load_all((ROOT / 'infrastructure/dns/resources.yaml').read_text())
           if obj['kind'] == 'Service')['spec']
edge = next(obj for obj in yaml.safe_load_all((ROOT / 'infrastructure/edge/resources.yaml').read_text())
            if obj['kind'] == 'EnvoyProxy')['spec']['provider']['kubernetes']['envoyService']
for service in (dns, edge):
    assert service['externalTrafficPolicy'] == 'Cluster'
    assert not service.get('loadBalancerClass'), 'Keep existing Services upgradeable without changing their immutable class'
# Bound stale /32 retention after a silent controller failure.
timers = peer['spec']['timers']
assert 3 <= timers['holdTimeSeconds'] <= 15
assert 1 <= timers['keepAliveTimeSeconds'] <= timers['holdTimeSeconds'] // 3
assert peer['spec']['gracefulRestart']['enabled'] is False
print('Off-link pools, LAN peers, address conflicts, private-only advertisements and BGP forwarding passed.')
