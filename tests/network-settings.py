#!/usr/bin/env python3
"""Catch LAN/pool mistakes before bootstrap and bound optional BGP exposure."""
import importlib.util
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('settings', ROOT / 'scripts/validate-cluster.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
settings = yaml.safe_load((ROOT / 'clusters/base/defaults.yaml').read_text())['data']
settings.update(yaml.safe_load((ROOT / 'clusters/laptops/settings.yaml').read_text())['data'])
module.validate(settings)
# Subsequent rejection cases use an isolated fixture, allowing real profiles to
# change subnets and deliberately enable BGP without breaking these checks.
settings.update(LAN_CIDR='192.168.2.0/24', DNS_CLIENT_CIDR='192.168.2.0/24',
                API_HOST='192.168.2.153', LB_START='192.168.2.240', LB_STOP='192.168.2.249',
                EDGE_IP='192.168.2.240', DNS_IP='192.168.2.242',
                POD_CIDR='10.42.0.0/16', SERVICE_CIDR='10.43.0.0/16', CLUSTER_DNS='10.43.0.10',
                DNS_UPSTREAMS='1.1.1.1 9.9.9.9', PUBLIC_EDGE_IP='NOT_CONFIGURED',
                BGP_ENABLED='false', BGP_ROUTER_IP='NOT_CONFIGURED',
                BGP_LOCAL_ASN='64513', BGP_PEER_ASN='64512')


def rejected(**overrides):
    try:
        module.validate({**settings, **overrides})
    except (AssertionError, ValueError):
        return
    raise AssertionError(f'Unsafe configuration accepted: {overrides}')


# A 192.168 address is not assumed to be in any particular /24 or /16.
for subnet in (0, 1, 2, 50, 255):
    prefix = f'192.168.{subnet}'
    module.validate({**settings, 'LAN_CIDR': prefix + '.0/24',
                     'DNS_CLIENT_CIDR': prefix + '.0/24', 'API_HOST': prefix + '.153',
                     'LB_START': prefix + '.240', 'LB_STOP': prefix + '.249',
                     'EDGE_IP': prefix + '.240', 'DNS_IP': prefix + '.242'})
module.validate({**settings, 'LAN_CIDR': '192.168.2.0/23', 'DNS_CLIENT_CIDR': '192.168.2.0/23'})
module.validate({**settings, 'LAN_CIDR': '192.168.0.0/16', 'DNS_CLIENT_CIDR': '192.168.0.0/16'})
rejected(LAN_CIDR='192.168.50.0/24')
rejected(LB_START='192.168.2.0')
rejected(LB_STOP='192.168.2.255')
rejected(LB_STOP='192.168.3.1')
rejected(API_HOST='192.168.2.245')  # Even currently unused pool addresses conflict.
rejected(API_HOST='999.168.2.153')
rejected(API_HOST='127.0.0.1')
rejected(API_HOST='0.0.0.0')
rejected(API_VIP='192.168.2.245', API_VIP_INTERFACE='eth0')
rejected(API_VIP='192.168.2.10')
module.validate({**settings, 'API_VIP': '192.168.2.10', 'API_VIP_INTERFACE': 'eth0'})
rejected(POD_CIDR='192.168.0.0/16')
rejected(SERVICE_CIDR='192.168.2.0/24', CLUSTER_DNS='192.168.2.10')
rejected(BGP_ENABLED='true')  # Router must be chosen explicitly.
rejected(BGP_ENABLED='true', BGP_ROUTER_IP='192.168.50.1')
rejected(BGP_ENABLED='true', BGP_ROUTER_IP='192.168.2.245')
rejected(BGP_ENABLED='true', BGP_ROUTER_IP='192.168.2.1', BGP_PEER_ASN='64513')
rejected(BGP_ENABLED='true', BGP_ROUTER_IP='192.168.2.1', BGP_PEER_ASN='123')
module.validate({**settings, 'BGP_ENABLED': 'true', 'BGP_ROUTER_IP': '192.168.2.1'})

bgp = list(yaml.safe_load_all((ROOT / 'infrastructure/bgp/resources.yaml').read_text()))
config, peer, advertisement = bgp
assert config['spec']['nodeSelector'] == {'matchExpressions': [
    {'key': 'node-role.kubernetes.io/control-plane', 'operator': 'Exists'}]}
assert 'localPort' not in config['spec']['bgpInstances'][0]
rules = advertisement['spec']['advertisements']
assert len(rules) == 2
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
print('LAN prefixes, pool/API conflicts, BGP opt-in and private-only service advertisements passed.')
