#!/usr/bin/env python3
"""Check documentation links and the independently copied downstream starter."""
import argparse
import pathlib
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import yaml
from render import ROOT, configured, profile_settings, read, run, write


def static():
    # Broken local links otherwise survive manifest validation indefinitely.
    documents = [ROOT / 'README.md', ROOT / 'AGENTS.md']
    documents += list((ROOT / 'docs').glob('*.md'))
    documents += list((ROOT / 'examples').rglob('*.md'))
    for path in documents:
        for target in re.findall(r'\]\(([^\s)]+)\)', path.read_text()):
            if re.match(r'^[a-z]+:', target):
                continue
            filename, _, anchor = target.partition('#')
            destination = path.parent / filename if filename else path
            assert destination.exists(), f'{path.relative_to(ROOT)}: missing link {target}'
            if anchor and destination.suffix == '.md':
                headings = re.findall(r'^#+\s+(.+)$', destination.read_text(), re.M)
                anchors = {re.sub(r'[^\w\- ]', '', h.lower()).replace(' ', '-') for h in headings}
                assert anchor in anchors, f'{path.relative_to(ROOT)}: missing heading {target}'
    reference = (ROOT / 'docs/scripts.md').read_text()
    for script in (ROOT / 'scripts').glob('*.sh'):
        assert f'`{script.name}`' in reference, f'Undocumented script: {script.name}'
    assert profile_settings()['BASE_CONTRACT_VERSION'] == '1'
    starter = ROOT / 'examples/downstream-repository'
    assert (starter / 'README.md').is_file() and (starter / 'AGENTS.md').is_file()
    assert read(ROOT / 'examples/cnpg-cluster.yaml')[0]['spec']['imageName'] == profile_settings()['PG_IMAGE']
    print(f'Documentation links, script coverage and downstream contract checked ({len(documents)} documents).')


def render_starter():
    source = ROOT / 'examples/downstream-repository'
    base_names = {d['metadata']['name'] for d in read(ROOT / 'clusters/base/reconciliation.yaml')}
    with tempfile.TemporaryDirectory(prefix='elektro-downstream-') as directory:
        destination = pathlib.Path(directory) / 'applications'
        shutil.copytree(source, destination)
        for name, domain in [('laptops', 'internal'), ('factory', 'factory.internal')]:
            # The new repository must build without access to the base checkout.
            shutil.copytree(destination / 'clusters/example', destination / 'clusters' / name)
            values = dict(profile_settings(), CLUSTER_NAME=name, INTERNAL_DOMAIN=domain,
                          IDENTITY_HOST=f'keycloak.admin.{domain}')
            def build(path):
                text = run('kubectl', 'kustomize', str(destination / path))
                for key, value in values.items():
                    text = text.replace('${' + key + '}', value)
                assert not re.search(r'\$\{[A-Z_]+\}', text), f'Unresolved settings in {path}'
                return [d for d in yaml.safe_load_all(text) if d]
            children = build(f'clusters/{name}')
            child_names = {d['metadata']['name'] for d in children}
            seen = set()
            for child in children:
                assert child['metadata']['namespace'] == 'flux-system'
                spec = child['spec']
                assert spec['sourceRef']['name'] == 'applications'
                assert {d['name'] for d in spec['dependsOn']} <= base_names | child_names
                assert spec['postBuild']['substituteFrom'] == [{'kind': 'ConfigMap', 'name': 'cluster-settings'}]
                path = spec['path'].removeprefix('./')
                objects = build(path)
                for obj in objects:
                    identity = (obj['apiVersion'], obj['kind'], obj['metadata'].get('namespace'), obj['metadata']['name'])
                    assert identity not in seen, f'Duplicate owner: {identity}'
                    seen.add(identity)
                stage = path.split('/')[-1]
                if stage == 'routes':
                    route = next(o for o in objects if o['kind'] == 'HTTPRoute')
                    assert route['metadata']['namespace'] == 'edge'
                    assert route['spec']['hostnames'] == [f'demo.{domain}']
                    assert spec['healthCheckExprs'], 'Routes need resolved references and acceptance'
                else:
                    assert spec['decryption']['secretRef']['name'] == 'sops-age'
                write(ROOT / 'rendered/downstream' / f'{name}-{stage}.yaml', objects)
            write(ROOT / 'rendered/downstream' / f'{name}-reconciliation.yaml', children)
            # Public/private alias examples must also follow a future profile's suffix.
            aliases = configured(ROOT / 'examples/public-exposure/routes/resources.yaml', values)
            private = next(d for d in aliases if d['kind'] == 'HTTPRoute' and
                           d['spec']['parentRefs'][0]['name'] == 'platform')
            assert private['spec']['hostnames'] == [f'foo.{domain}']
    print('Standalone downstream copy builds for laptops and factory, with independent paths and domains.')


def runtime():
    assert run('kubectl', 'config', 'current-context').strip() == 'kind-elektro-validation'
    attachment = read(ROOT / 'examples/downstream-source.yaml')
    subprocess.run(['kubectl', 'apply', '--server-side', '--dry-run=server', '--validate=strict', '-f', '-'],
                   input=yaml.safe_dump_all(attachment), text=True, check=True)
    for name in ['laptops', 'factory']:
        run('kubectl', 'apply', '--server-side', '--dry-run=server', '--validate=strict', '-f',
            str(ROOT / 'rendered/downstream' / f'{name}-reconciliation.yaml'))
    run('kubectl', 'label', 'node', '--all', 'elektro.local/workloads=true', '--overwrite')
    run('kubectl', 'apply', '-f', str(ROOT / 'rendered/downstream/laptops-workloads.yaml'))
    try:
        run('kubectl', '-n', 'app-demo', 'rollout', 'status', 'deployment/demo', '--timeout=180s')
        run('kubectl', 'apply', '--server-side', '--dry-run=server', '--validate=strict', '-f',
            str(ROOT / 'rendered/downstream/laptops-routes.yaml'))
        run('kubectl', 'apply', '--server-side', '--dry-run=server', '--validate=strict', '-f',
            str(ROOT / 'examples/cnpg-network.yaml'))
        # Real image, restricted Pod security and read-only filesystem; no auth claim.
        forward = subprocess.Popen(['kubectl', '-n', 'app-demo', 'port-forward', 'service/demo', '18085:8080'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for attempt in range(30):
                try:
                    with urllib.request.urlopen('http://127.0.0.1:18085/hostname', timeout=2) as response:
                        assert response.status == 200 and response.read().decode().startswith('demo-')
                    break
                except (OSError, urllib.error.URLError):
                    if attempt == 29:
                        raise
                    time.sleep(1)
        finally:
            forward.terminate()
            forward.wait(timeout=10)
    finally:
        run('kubectl', '-n', 'app-demo', 'delete', 'deployment/demo', 'service/demo', '--wait=false')
    print('Downstream schemas/admission and actual diagnostic workload startup passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--render', action='store_true')
    parser.add_argument('--runtime', action='store_true')
    args = parser.parse_args()
    static()
    if args.render:
        render_starter()
    if args.runtime:
        runtime()
