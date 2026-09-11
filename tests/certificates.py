#!/usr/bin/env python3
"""Private TLS regression checks. Runtime writes only to the disposable CI cluster."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import yaml
from render import ROOT, read, run, write


def static():
    objects = read(ROOT / 'infrastructure/certificates/resources.yaml')
    root = next(o for o in objects if o['kind'] == 'Certificate' and o['spec'].get('isCA'))
    edge = next(o for o in objects if o['kind'] == 'Certificate' and o['metadata']['name'] == 'edge-tls')
    assert root['spec']['privateKey']['rotationPolicy'] == 'Never'
    assert edge['spec']['privateKey']['rotationPolicy'] == 'Always'
    assert int(root['spec']['renewBefore'][:-1]) > int(edge['spec']['duration'][:-1])
    assert 0 < int(edge['spec']['renewBefore'][:-1]) < int(edge['spec']['duration'][:-1])
    print('Root trust/key and leaf renewal lifetimes checked.')


def render():
    # Exercise BOTH levels of Kustomize patching and final Flux substitution.
    phase = next(o for o in read(ROOT / 'clusters/base/reconciliation.yaml')
                 if o['metadata']['name'] == 'certificates')
    with tempfile.TemporaryDirectory(prefix='elektro-certificate-render-') as temp:
        directory = Path(temp)
        write(directory / 'phase.yaml', [phase])
        write(directory / 'names.yaml', read(ROOT / 'examples/private-app-certificate-names.yaml'))
        write(directory / 'kustomization.yaml', [{
            'apiVersion': 'kustomize.config.k8s.io/v1beta1', 'kind': 'Kustomization',
            'resources': ['phase.yaml'], 'patches': [{'path': 'names.yaml'}]}])
        patched = yaml.safe_load(run('kubectl', 'kustomize', str(directory)))
        assert patched['metadata']['name'] == 'certificates'
        write(directory / 'input.yaml', read(ROOT / 'infrastructure/certificates/resources.yaml'))
        write(directory / 'kustomization.yaml', [{
            'apiVersion': 'kustomize.config.k8s.io/v1beta1', 'kind': 'Kustomization',
            'resources': ['input.yaml'], 'patches': patched['spec']['patches']}])
        raw = run('kubectl', 'kustomize', str(directory))
        for profile, suffix in [('laptops', 'internal'), ('factory', 'factory.internal')]:
            text = raw.replace('${INTERNAL_DOMAIN}', suffix)
            objects = list(yaml.safe_load_all(text))
            edge = next(o for o in objects if o['kind'] == 'Certificate' and o['metadata']['name'] == 'edge-tls')
            assert set(edge['spec']['dnsNames']) == {
                '*.' + suffix, '*.admin.' + suffix, '*.test.' + suffix,
                '*.staging.' + suffix, 'demo.' + suffix}
            write(ROOT / 'rendered' / f'certificates-{profile}.yaml', objects)
    print('Exact SAN example preserves wildcards through base/child Flux patches for two suffixes.')


def secret(namespace, name):
    obj = json.loads(run('kubectl', '-n', namespace, 'get', 'secret', name, '-o', 'json'))
    return {key: base64.b64decode(value) for key, value in obj['data'].items()}


def revision(namespace, name):
    return int(json.loads(run('kubectl', '-n', namespace, 'get', 'certificate', name, '-o', 'json'))['status']['revision'])


def wait_revision(namespace, name, expected):
    run('kubectl', '-n', namespace, 'wait', f'certificate/{name}',
        f'--for=jsonpath={{.status.revision}}={expected}', '--timeout=180s')
    run('kubectl', '-n', namespace, 'wait', f'certificate/{name}',
        '--for=condition=Ready', '--timeout=180s')


def verify(ca, leaf, host, accepted=True):
    result = subprocess.run(['openssl', 'verify', '-CAfile', str(ca), '-no-CApath',
                             '-no-CAstore', '-purpose', 'sslserver',
                             '-verify_hostname', host, str(leaf)],
                            text=True, capture_output=True)
    assert (result.returncode == 0) == accepted, (host, result.stdout, result.stderr)


def runtime():
    assert run('kubectl', 'config', 'current-context').strip() == 'kind-elektro-validation'
    # metrics.py --runtime already installed the pinned cert-manager chart.
    run('kubectl', 'apply', '-f', str(ROOT / 'rendered/certificates-laptops.yaml'))
    run('kubectl', '-n', 'cert-manager', 'wait', 'certificate/platform-root-ca',
        '--for=condition=Ready', '--timeout=180s')
    run('kubectl', '-n', 'edge', 'wait', 'certificate/edge-tls',
        '--for=condition=Ready', '--timeout=180s')
    with tempfile.TemporaryDirectory(prefix='elektro-tls-') as temp:
        directory = Path(temp)
        ca, leaf = directory / 'root.pem', directory / 'edge.pem'
        root_before, edge_before = secret('cert-manager', 'platform-root-ca'), secret('edge', 'edge-tls')
        ca.write_bytes(root_before['ca.crt'])
        leaf.write_bytes(edge_before['tls.crt'])
        for host in ['demo.internal', 'keycloak.admin.internal', 'grafana.admin.internal',
                     'foo-a7c92e.test.internal', 'foo-b41d08.test.internal', 'foo.staging.internal']:
            verify(ca, leaf, host)
        for host in ['unlisted.internal', 'x.foo.test.internal', 'internal', 'example.org']:
            verify(ca, leaf, host, accepted=False)
        # Deliberate reissuance in CI: root must retain its key and remain usable
        # with the originally distributed public root. Never log private key data.
        root_revision = revision('cert-manager', 'platform-root-ca')
        run('kubectl', '-n', 'cert-manager', 'patch', 'certificate', 'platform-root-ca',
            '--type=merge', '-p', json.dumps({'spec': {'duration': '87624h'}}))
        wait_revision('cert-manager', 'platform-root-ca', root_revision + 1)
        root_after = secret('cert-manager', 'platform-root-ca')
        assert hashlib.sha256(root_after['tls.key']).digest() == hashlib.sha256(root_before['tls.key']).digest()
        assert root_after['tls.crt'] != root_before['tls.crt']
        # Another profile's rendered SANs force leaf reissuance, exercising key
        # rotation and the deeper ordinary wildcard against the old trusted root.
        edge_revision = revision('edge', 'edge-tls')
        factory = next(o for o in read(ROOT / 'rendered/certificates-factory.yaml')
                       if o['kind'] == 'Certificate' and o['metadata']['name'] == 'edge-tls')
        subprocess.run(['kubectl', 'apply', '-f', '-'], input=yaml.safe_dump(factory),
                       text=True, check=True)
        wait_revision('edge', 'edge-tls', edge_revision + 1)
        edge_after = secret('edge', 'edge-tls')
        assert hashlib.sha256(edge_after['tls.key']).digest() != hashlib.sha256(edge_before['tls.key']).digest()
        leaf.write_bytes(edge_after['tls.crt'])
        for host in ['demo.factory.internal', 'unlisted.factory.internal',
                     'grafana.admin.factory.internal', 'foo-123.test.factory.internal']:
            verify(ca, leaf, host)
        verify(ca, leaf, 'demo.internal', accepted=False)
    print('Real CA/leaf issuance, exact/internal wildcard checks, root-key preservation and leaf rotation passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--render', action='store_true')
    parser.add_argument('--runtime', action='store_true')
    args = parser.parse_args()
    static()
    if args.render:
        render()
    if args.runtime:
        runtime()
