#!/usr/bin/env python3
"""Generate a reviewable EdgeOS configuration; never write to a router or cluster."""
import argparse
import importlib.util
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cluster_validator', ROOT / 'scripts/validate-cluster.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def kubectl(*args):
    return subprocess.check_output(['kubectl', '--request-timeout=30s', *args], text=True)


def profile_settings(name):
    if not re.fullmatch(r'[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?', name) or name == 'base':
        raise ValueError('Cluster name must be a DNS label other than base')
    overrides = kubectl('patch', '--local', '--type=merge', '--patch', '{}',
                        '-f', str(ROOT / 'clusters' / name / 'settings.yaml'), '-o', 'json')
    settings = json.loads(kubectl('patch', '--local', '--type=merge', '--patch', overrides,
                                 '-f', str(ROOT / 'clusters/base/defaults.yaml'), '-o', 'json'))['data']
    if settings['CLUSTER_NAME'] != name:
        raise ValueError('CLUSTER_NAME must match its profile directory')
    validator.validate(settings)
    return settings


def discover_nodes(settings):
    context = json.loads(kubectl('config', 'view', '--minify', '-o', 'json'))
    expected = f"https://{settings['API_HOST']}:6443"
    if context['clusters'][0]['cluster']['server'] != expected:
        raise ValueError(f'Current kubeconfig must point at {expected}; select the intended cluster first')
    live = kubectl('-n', 'flux-system', 'get', 'configmap', 'cluster-settings', '--ignore-not-found', '-o', 'json')
    if live.strip() and json.loads(live)['data']['CLUSTER_NAME'] != settings['CLUSTER_NAME']:
        raise ValueError('Live cluster identifies itself as another profile')
    nodes = json.loads(kubectl('get', 'nodes', '-l', 'node-role.kubernetes.io/control-plane', '-o', 'json'))['items']
    addresses = []
    for node in nodes:
        ips = [entry['address'] for entry in node.get('status', {}).get('addresses', [])
               if entry['type'] == 'InternalIP' and ipaddress.ip_address(entry['address']).version == 4]
        if len(ips) != 1:
            raise ValueError(f"Controller {node['metadata']['name']} needs exactly one IPv4 InternalIP")
        addresses.extend(ips)
    return addresses


def router_config(settings, addresses, dns_forwarding=False, *, router_id=None, include_public=False):
    validator.validate(settings)
    lan = ipaddress.IPv4Network(settings['LAN_CIDR'])
    nodes = [ipaddress.IPv4Address(address) for address in addresses]
    if not nodes or len(nodes) != len(set(nodes)):
        raise ValueError('Supply one or more distinct stable controller IPs (--node-ip or --discover)')
    for node in nodes:
        if not lan.network_address < node < lan.broadcast_address:
            raise ValueError(f'Controller {node} is not a usable address on LAN_CIDR')
        if str(node) in (settings['BGP_ROUTER_IP'], settings.get('API_VIP')):
            raise ValueError(f'Controller {node} must be a physical node, not a router/API VIP')
    name = 'ELEKTRO-' + settings['CLUSTER_NAME'].upper()
    local_asn, peer_asn = int(settings['BGP_LOCAL_ASN']), int(settings['BGP_PEER_ASN'])
    router = settings['BGP_ROUTER_IP']
    if router_id is not None:
        router_id = ipaddress.IPv4Address(router_id)
        if router_id.is_unspecified or router_id.is_multicast or int(router_id) == 0xffffffff:
            raise ValueError('Router ID must be a nonzero unicast IPv4 address')
    if dns_forwarding and ipaddress.IPv4Address(router) not in ipaddress.IPv4Network(settings['DNS_CLIENT_CIDR']):
        raise ValueError('Router DNS forwarding requires BGP_ROUTER_IP inside DNS_CLIENT_CIDR')
    routes = [(10, 'EDGE_IP'), (20, 'DNS_IP')]
    if include_public:
        if settings['PUBLIC_EDGE_IP'] == 'NOT_CONFIGURED' or settings['IDENTITY_HOST'].endswith('.internal'):
            raise ValueError('--include-public requires PUBLIC_EDGE_IP and a public IDENTITY_HOST; follow the public-exposure runbook')
        routes.append((30, 'PUBLIC_EDGE_IP'))
    lines = [
        '# Generated from clusters/' + settings['CLUSTER_NAME'] + '/settings.yaml.',
        '# Verify stable controller leases, existing BGP ASN/router-id and policy names.',
        '# Review compare; then run commit; save; exit in the router CLI.',
        'configure',
    ]
    for rule, key in routes:
        lines += [f'set policy prefix-list {name}-IN rule {rule} action permit',
                  f"set policy prefix-list {name}-IN rule {rule} prefix {settings[key]}/32"]
    lines += [f'set policy prefix-list {name}-OUT rule 10 action deny',
              f'set policy prefix-list {name}-OUT rule 10 prefix 0.0.0.0/0',
              f'set policy prefix-list {name}-OUT rule 10 le 32']
    if router_id is not None:
        lines.append(f'set protocols bgp {peer_asn} parameters router-id {router_id}')
    for node in sorted(nodes):
        prefix = f'set protocols bgp {peer_asn} neighbor {node}'
        lines += [f'{prefix} remote-as {local_asn}', f'{prefix} passive',
                  f'{prefix} prefix-list import {name}-IN',
                  f'{prefix} prefix-list export {name}-OUT', f'{prefix} maximum-prefix {len(routes)}']
    if dns_forwarding:
        lines.append(f"set service dns forwarding options server=/{settings['INTERNAL_DOMAIN']}/{settings['DNS_IP']}")
    lines.append('compare')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cluster', help='Profile name, e.g. laptops')
    peers = parser.add_mutually_exclusive_group(required=True)
    peers.add_argument('--node-ip', action='append', help='Stable controller IPv4; repeat for HA; no cluster access')
    peers.add_argument('--discover', action='store_true', help='Read controller InternalIPs from the checked kubeconfig')
    parser.add_argument('--dns-forwarding', action='store_true', help='Include suffix forwarding; enable only after DNS acceptance')
    parser.add_argument('--router-id', help='Explicitly set the global EdgeOS router ID; omitted by default to preserve existing BGP')
    parser.add_argument('--include-public', action='store_true', help='Include the separately enabled public gateway /32 and raise the prefix limit')
    args = parser.parse_args()
    settings = profile_settings(args.cluster)
    addresses = discover_nodes(settings) if args.discover else args.node_ip
    print(router_config(settings, addresses, args.dns_forwarding,
                        router_id=args.router_id, include_public=args.include_public), end='')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, KeyError, ValueError, IndexError, OSError, subprocess.CalledProcessError) as error:
        print(f'Cannot generate BGP configuration: {error}', file=sys.stderr)
        sys.exit(1)
