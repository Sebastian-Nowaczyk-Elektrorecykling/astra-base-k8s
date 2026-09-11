#!/usr/bin/env python3
"""Exercise the actual Kubernetes CEL policies; runs only in disposable CI kind."""
import copy
import pathlib
import subprocess
import time
import yaml
from render import profile_settings

ROOT = pathlib.Path(__file__).resolve().parents[1]

def call(objects):
    return subprocess.run(['kubectl', 'apply', '--server-side', '--field-manager=elektro-validation',
                           '--dry-run=server', '--validate=strict', '-f', '-'],
                          input=yaml.safe_dump_all(objects), text=True, capture_output=True)

def check(obj, reason=None):
    result = call([obj])
    if reason is None:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode != 0 and reason in result.stderr, result.stdout + result.stderr

assert subprocess.check_output(['kubectl', 'config', 'current-context'], text=True).strip() == 'kind-elektro-validation'
settings = profile_settings()

def render(path, values=settings):
    text = (ROOT / path).read_text()
    for key, value in values.items():
        text = text.replace('${' + key + '}', value)
    return list(yaml.safe_load_all(text))

def route(host, listener='apps', public=False):
    return {'apiVersion': 'gateway.networking.k8s.io/v1', 'kind': 'HTTPRoute',
            'metadata': {'name': 'domain-check', 'namespace': 'edge',
                         'labels': {'elektro.local/exposure': 'public' if public else 'private'}},
            'spec': {'parentRefs': [{'name': 'public' if public else 'platform', 'sectionName': listener}],
                     'hostnames': [host], 'rules': [{'backendRefs': [{'name': 'demo', 'namespace': 'app-demo', 'port': 8080}]}]}}

for host, listener in [('foo.internal', 'apps'), ('longhorn.admin.internal', 'admin'),
                       ('foo-a7c92e.test.internal', 'test'), ('foo-b41d08.test.internal', 'test'),
                       ('foo.staging.internal', 'staging'), ('foo-candidate.staging.internal', 'staging')]:
    check(route(host, listener))
for host, listener in [('k8s1.hosts.internal', 'apps'), ('test.internal', 'apps'),
                       ('foo.test.internal', 'apps'), ('deep.foo.test.internal', 'test'),
                       ('foo.staging.internal', 'test'), ('foo.internal', 'admin'),
                       ('fuzzy.elektrorecykling.pl', 'apps')]:
    check(route(host, listener), 'Internal hostnames must match')
check(route('*.test.internal', 'test'), 'Routes require exact hostnames')
check(route('fuzzy.elektrorecykling.pl', public=True), 'public exposure must be explicitly enabled')
private_policy = render('infrastructure/access/resources.yaml')[0]
broken_policy = copy.deepcopy(private_policy)
broken_policy['spec']['targetRefs'].pop()
check(broken_policy, 'Security policies must cover every')

# A DNS exception must not permit an alternate application entry point.
dns_service = next(d for d in yaml.safe_load_all((ROOT / 'rendered/infrastructure-dns.yaml').read_text())
                   if d['kind'] == 'Service')
check(dns_service)
for change in ['namespace', 'name', 'address', 'port', 'selector', 'nodeports', 'sources', 'deny']:
    bad = copy.deepcopy(dns_service)
    if change == 'namespace':
        bad['metadata']['namespace'] = 'app-demo'
    elif change == 'name':
        bad['metadata']['name'] = 'another-dns'
    elif change == 'address':
        bad['metadata']['annotations']['lbipam.cilium.io/ips'] = settings['EDGE_IP']
    elif change == 'port':
        bad['spec']['ports'][0]['port'] = 443
    elif change == 'selector':
        bad['spec']['selector'] = {'app': 'unprotected-ui'}
    elif change == 'nodeports':
        bad['spec']['allocateLoadBalancerNodePorts'] = True
    elif change == 'sources':
        bad['spec']['loadBalancerSourceRanges'] = ['0.0.0.0/0']
    elif change == 'deny':
        bad['metadata']['annotations']['service.cilium.io/src-ranges-policy'] = 'deny'
    check(bad, 'Only managed gateways or the restricted LAN DNS service')

# Switch only the disposable cluster's admission settings to test explicit public opt-in.
values = dict(settings, PUBLIC_EDGE_IP='192.168.50.241', IDENTITY_HOST='login.elektrorecykling.pl')
assert values['PUBLIC_EDGE_IP'] != values['EDGE_IP']
subprocess.run(['kubectl', 'apply', '--server-side', '--field-manager=elektro-validation', '-f', '-'],
               input=yaml.safe_dump_all(render('infrastructure/admission/guards.yaml', values)),
               text=True, check=True, stdout=subprocess.DEVNULL)
for attempt in range(30):
    if call([route('fuzzy.elektrorecykling.pl', public=True)]).returncode == 0:
        break
    time.sleep(1)
else:
    raise AssertionError('Updated public-exposure admission policy did not become effective')
subprocess.run(['kubectl', 'create', 'namespace', 'app-foo'], check=True, stdout=subprocess.DEVNULL)
for part in ['edge', 'certificate', 'access', 'routes']:
    for obj in render(f'examples/public-exposure/{part}/resources.yaml', values):
        check(obj)
for host in ['foo.internal', 'bar.internal', 'longhorn.admin.internal', 'k8s1.hosts.internal', 'internal']:
    check(route(host, public=True), 'Public routes require the explicit exposure label')
check(route('*.elektrorecykling.pl', public=True), 'Routes require exact hostnames')
no_label = route('fuzzy.elektrorecykling.pl', public=True)
no_label['metadata'].pop('labels')
check(no_label, 'Public routes require the explicit exposure label')
check(route(values['IDENTITY_HOST'], public=True), 'Public routes require the explicit exposure label')
infra = route('fuzzy.elektrorecykling.pl', public=True)
infra['spec']['rules'][0]['backendRefs'][0].update(namespace='identity', name='keycloak')
check(infra, 'Public application routes must directly reference')
infra['spec']['rules'][0]['backendRefs'][0].update(namespace='kube-system', name='lan-dns', port=53)
check(infra, 'Public application routes must directly reference')
identity = render('examples/public-exposure/routes/resources.yaml', values)[0]
for path in ['/admin', '/realms/master', '/', '/metrics', '/realms/elektro-other']:
    bad = copy.deepcopy(identity)
    bad['spec']['rules'][0]['matches'] = [{'path': {'type': 'PathPrefix', 'value': path}}]
    check(bad, 'Only Keycloak may use')
bad = copy.deepcopy(identity)
bad['spec']['rules'][0]['backendRefs'][0]['filters'] = [{'type': 'RequestHeaderModifier', 'requestHeaderModifier': {'set': [{'name': 'x-test', 'value': 'yes'}]}}]
check(bad, 'Only Keycloak may use')
public_proxy = render('examples/public-exposure/edge/resources.yaml', values)[0]
public_proxy['spec']['provider']['kubernetes']['envoyService']['annotations']['lbipam.cilium.io/ips'] = values['EDGE_IP']
check(public_proxy, 'Only managed EnvoyProxy resources')
public_gateway = render('examples/public-exposure/edge/resources.yaml', values)[2]
public_gateway['spec']['listeners'][1]['hostname'] = '*.internal'
check(public_gateway, 'The public Gateway has only')
# A different private suffix uses the same routes, certificates and admission rules.
alternate = dict(settings, INTERNAL_DOMAIN='factory.internal', IDENTITY_HOST='keycloak.admin.factory.internal')
subprocess.run(['kubectl', 'apply', '--server-side', '--field-manager=elektro-validation', '-f', '-'],
               input=yaml.safe_dump_all(render('infrastructure/admission/guards.yaml', alternate)),
               text=True, check=True, stdout=subprocess.DEVNULL)
for attempt in range(30):
    if call([route('foo.factory.internal')]).returncode == 0:
        break
    time.sleep(1)
else:
    raise AssertionError('Second cluster domain was not accepted')
for host, listener in [('foo.factory.internal', 'apps'), ('foo-42.test.factory.internal', 'test'),
                       ('foo.staging.factory.internal', 'staging'), ('longhorn.admin.factory.internal', 'admin')]:
    check(route(host, listener))
for host in ['foo.internal', 'k8s9.hosts.factory.internal', 'hosts.factory.internal', 'deep.foo.factory.internal']:
    check(route(host), 'Internal hostnames must match')
for part in ['edge', 'certificates', 'access', 'routes']:
    for obj in render(f'infrastructure/{part}/resources.yaml', alternate):
        check(obj)
# Restore base admission before subsequent startup smoke checks.
subprocess.run(['kubectl', 'apply', '--server-side', '--field-manager=elektro-validation', '-f',
                'rendered/infrastructure-admission.yaml'], check=True, stdout=subprocess.DEVNULL)
print('Internal groups, exact hosts, independent public aliases and public identity restrictions passed.')
