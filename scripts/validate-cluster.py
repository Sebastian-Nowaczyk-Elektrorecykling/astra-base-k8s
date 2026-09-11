#!/usr/bin/env python3
"""Validate merged cluster settings supplied as JSON; workstation-only preflight."""
import ipaddress
import json
import re
import sys


def validate(data):
    label = r'[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?'

    def hostname(value):
        return len(value) <= 253 and all(re.fullmatch(label, part) for part in value.split('.'))

    def address(key):
        ip = ipaddress.IPv4Address(data[key])
        assert not (ip.is_unspecified or ip.is_loopback or ip.is_multicast), f'{key}: choose a reachable unicast address'
        return ip

    assert re.fullmatch(label, data['CLUSTER_NAME']) and data['CLUSTER_NAME'] != 'base', 'Invalid CLUSTER_NAME'
    domain = data['INTERNAL_DOMAIN']
    assert hostname(domain) and (domain == 'internal' or domain.endswith('.internal')), 'INTERNAL_DOMAIN must be internal or a subdomain of it'
    assert hostname(data['API_HOST']), 'API_HOST must be a bare IPv4 address or DNS name'
    assert hostname(data['IDENTITY_HOST']), 'IDENTITY_HOST must be a hostname'
    if data['IDENTITY_HOST'].endswith('.internal'):
        assert data['IDENTITY_HOST'] == 'keycloak.admin.' + domain, 'Private IDENTITY_HOST must be keycloak.admin.INTERNAL_DOMAIN'
    pod = ipaddress.IPv4Network(data['POD_CIDR'])
    service = ipaddress.IPv4Network(data['SERVICE_CIDR'])
    clients = ipaddress.IPv4Network(data['DNS_CLIENT_CIDR'])
    assert clients.prefixlen > 0 and not clients.is_multicast, 'DNS_CLIENT_CIDR must restrict access to your LAN/VPN'
    assert not pod.overlaps(service), 'Pod and Service networks overlap'
    assert not pod.overlaps(clients) and not service.overlaps(clients), 'Cluster address ranges overlap the client LAN/VPN'
    cluster_dns = address('CLUSTER_DNS')
    assert cluster_dns in service and cluster_dns not in [service.network_address, service.broadcast_address], 'CLUSTER_DNS must be a usable address in SERVICE_CIDR'
    start, stop = address('LB_START'), address('LB_STOP')
    assert start <= stop, 'LB_START must not exceed LB_STOP'
    vips = [address('DNS_IP'), address('EDGE_IP')]
    if data['PUBLIC_EDGE_IP'] != 'NOT_CONFIGURED':
        vips.append(address('PUBLIC_EDGE_IP'))
    assert len(set(vips)) == len(vips), 'DNS and gateway IPs must be distinct'
    for ip in vips:
        assert start <= ip <= stop, 'DNS/gateway LAN addresses must be inside LB_START..LB_STOP'
        assert ip not in pod and ip not in service, 'LAN virtual IPs cannot use Pod/Service addresses'
        assert str(ip) != data['API_HOST'], 'API_HOST must not share a DNS/gateway service IP'
    upstreams = data['DNS_UPSTREAMS'].split()
    assert 1 <= len(upstreams) <= 15, 'Configure between one and fifteen DNS upstreams'
    for upstream in upstreams:
        parts = upstream.split(':')
        ip = ipaddress.IPv4Address(parts[0])
        assert not (ip.is_loopback or ip.is_unspecified or ip.is_multicast), 'Use reachable upstream DNS IPs'
        assert ip not in vips and ip not in service, 'DNS must not forward back to itself or cluster DNS'
        assert len(parts) == 1 or (len(parts) == 2 and 0 < int(parts[1]) < 65536), 'Invalid upstream DNS port'
    assert data['LAN_INTERFACE_REGEX'], 'Set LAN_INTERFACE_REGEX to the wired interfaces used for announcements'


if __name__ == '__main__':
    try:
        validate(json.load(sys.stdin)['data'])
    except (AssertionError, KeyError, ValueError, TypeError) as error:
        print(f'Invalid cluster settings: {error}', file=sys.stderr)
        sys.exit(1)
