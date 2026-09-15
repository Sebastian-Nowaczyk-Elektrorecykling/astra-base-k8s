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
    assert 'BGP_ENABLED' not in data and 'LAN_INTERFACE_REGEX' not in data, 'Remove retired BGP_ENABLED and LAN_INTERFACE_REGEX settings; BGP is always enabled and L2 is disabled'
    domain = data['INTERNAL_DOMAIN']
    assert hostname(domain) and (domain == 'internal' or domain.endswith('.internal')), 'INTERNAL_DOMAIN must be internal or a subdomain of it'
    assert hostname(data['API_HOST']), 'API_HOST must be a bare IPv4 address or DNS name'
    assert hostname(data['IDENTITY_HOST']), 'IDENTITY_HOST must be a hostname'
    if data['IDENTITY_HOST'].endswith('.internal'):
        assert data['IDENTITY_HOST'] == 'keycloak.admin.' + domain, 'Private IDENTITY_HOST must be keycloak.admin.INTERNAL_DOMAIN'
    pod = ipaddress.IPv4Network(data['POD_CIDR'])
    service = ipaddress.IPv4Network(data['SERVICE_CIDR'])
    lan = ipaddress.IPv4Network(data['LAN_CIDR'])
    assert 0 < lan.prefixlen <= 30 and not lan.is_multicast, 'LAN_CIDR must be a usable IPv4 LAN subnet'
    clients = ipaddress.IPv4Network(data['DNS_CLIENT_CIDR'])
    assert clients.prefixlen > 0 and not clients.is_multicast, 'DNS_CLIENT_CIDR must restrict access to your LAN/VPN'
    lb = ipaddress.IPv4Network(data['LB_CIDR'])
    private_ranges = [ipaddress.IPv4Network(cidr) for cidr in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
    assert lb.prefixlen <= 30 and any(lb.subnet_of(net) for net in private_ranges), 'LB_CIDR must be a usable RFC1918 service subnet'
    assert all(not lb.overlaps(net) for net in (lan, clients, pod, service)), 'LB_CIDR must not overlap node/client LANs or Pod/Service ranges; on-link clients would ARP instead of using BGP'
    assert not pod.overlaps(service), 'Pod and Service networks overlap'
    assert not pod.overlaps(lan) and not service.overlaps(lan), 'Cluster address ranges overlap LAN_CIDR'
    assert not pod.overlaps(clients) and not service.overlaps(clients), 'Cluster address ranges overlap the client LAN/VPN'
    cluster_dns = address('CLUSTER_DNS')
    assert cluster_dns in service and cluster_dns not in [service.network_address, service.broadcast_address], 'CLUSTER_DNS must be a usable address in SERVICE_CIDR'
    start, stop = address('LB_START'), address('LB_STOP')
    assert start <= stop, 'LB_START must not exceed LB_STOP'
    assert lb.network_address < start <= stop < lb.broadcast_address, 'The entire service pool must be inside LB_CIDR, excluding network/broadcast addresses'
    try:
        api = address('API_HOST')
    except ipaddress.AddressValueError:
        assert not re.fullmatch(r'[0-9.]+', data['API_HOST']), 'API_HOST resembles an invalid IPv4 address'
        api = None  # A stable API DNS name is also supported; no DNS lookup during local validation.
    if api is not None:
        assert api not in lb, 'The API address must be outside the routed Cilium service subnet'
        assert api not in pod and api not in service, 'API_HOST cannot use a Pod/Service address'
    vips = [address('DNS_IP'), address('EDGE_IP')]
    if data['PUBLIC_EDGE_IP'] != 'NOT_CONFIGURED':
        vips.append(address('PUBLIC_EDGE_IP'))
    assert len(set(vips)) == len(vips), 'DNS and gateway IPs must be distinct'
    for ip in vips:
        assert start <= ip <= stop, 'DNS/gateway virtual addresses must be inside LB_START..LB_STOP'
        assert ip not in pod and ip not in service, 'Virtual IPs cannot use Pod/Service addresses'
        assert str(ip) != data['API_HOST'], 'API_HOST must not share a DNS/gateway service IP'
    if 'API_VIP' in data:
        api_vip = address('API_VIP')
        assert lan.network_address < api_vip < lan.broadcast_address, 'The optional ARP API VIP must be inside LAN_CIDR'
        assert not start <= api_vip <= stop, 'API_VIP must be outside the entire service pool'
        assert data.get('API_VIP_INTERFACE'), 'Configure API_VIP_INTERFACE with the optional API VIP'
        assert api_vip != address('BGP_ROUTER_IP'), 'The optional API VIP must not duplicate the LAN router address'
    else:
        assert 'API_VIP_INTERFACE' not in data, 'API_VIP_INTERFACE requires an API_VIP'
    upstreams = data['DNS_UPSTREAMS'].split()
    assert 1 <= len(upstreams) <= 15, 'Configure between one and fifteen DNS upstreams'
    for upstream in upstreams:
        parts = upstream.split(':')
        ip = ipaddress.IPv4Address(parts[0])
        assert not (ip.is_loopback or ip.is_unspecified or ip.is_multicast), 'Use reachable upstream DNS IPs'
        assert ip not in vips and ip not in service, 'DNS must not forward back to itself or cluster DNS'
        assert len(parts) == 1 or (len(parts) == 2 and 0 < int(parts[1]) < 65536), 'Invalid upstream DNS port'
    router = address('BGP_ROUTER_IP')
    assert lan.network_address < router < lan.broadcast_address, 'The BGP router must be on the directly connected LAN'
    assert router != api, 'The BGP router and API endpoint must differ'
    local_asn, peer_asn = int(data['BGP_LOCAL_ASN']), int(data['BGP_PEER_ASN'])
    assert all(64512 <= asn <= 65534 for asn in (local_asn, peer_asn)), 'Use private 16-bit ASNs for this EdgeOS eBGP configuration'
    assert local_asn != peer_asn, 'eBGP requires different cluster and router ASNs'


if __name__ == '__main__':
    try:
        validate(json.load(sys.stdin)['data'])
    except (AssertionError, KeyError, ValueError, TypeError) as error:
        print(f'Invalid cluster settings: {error}', file=sys.stderr)
        sys.exit(1)
