#!/usr/bin/env python3
"""Run upstream CoreDNS and k3s in disposable CI containers; no user cluster access."""
import os
import json
import re
import pathlib
import subprocess
import tempfile
import time
import uuid

import dns.exception
import dns.message
import dns.query
import dns.rcode
import dns.rdatatype
import yaml
from render import profile_settings

ROOT = pathlib.Path(__file__).resolve().parents[1]
settings = profile_settings()
deployment = next(d for d in yaml.safe_load_all((ROOT / 'rendered/infrastructure-dns.yaml').read_text())
                  if d['kind'] == 'Deployment')
pod = deployment['spec']['template']['spec']
image = pod['containers'][0]['image']
uid = pod['securityContext']['runAsUser']
assert pod['securityContext']['runAsNonRoot'] and uid != 0
assert pod['containers'][0]['securityContext']['readOnlyRootFilesystem']


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()


def wait_for(test, description, seconds=120):
    deadline = time.monotonic() + seconds
    last_error = None
    while time.monotonic() < deadline:
        try:
            test()
            return
        except (AssertionError, OSError, subprocess.CalledProcessError, dns.exception.DNSException) as error:
            last_error = error
            time.sleep(2)
    details = str(last_error)
    if isinstance(last_error, subprocess.CalledProcessError):
        details += '\n' + (last_error.stdout or '') + (last_error.stderr or '')
    raise AssertionError('Timed out waiting for ' + description + ': ' + details)


name = 'elektro-dns-' + uuid.uuid4().hex[:10]
containers = []
docker('network', 'create', name)
try:
    with tempfile.TemporaryDirectory(prefix='elektro-dns-') as tmp:
        root = pathlib.Path(tmp)
        config = root / 'config'
        config.mkdir(mode=0o755)
        node_directory = root / 'node-hosts'
        node_directory.mkdir(mode=0o755)
        assert os.environ.get('GITHUB_ACTIONS') == 'true', 'The privileged disposable k3s fixture runs only in CI'
        k3s = name + '-k3s'
        version = re.search(r"^K3S_VERSION='([^']+)'", (ROOT / 'bootstrap/versions.env').read_text(), re.M)[1]
        docker('run', '--detach', '--privileged', '--name', k3s, '--network', name,
               '--tmpfs', '/run', '--tmpfs', '/var/run', '--cgroupns=host',
               'rancher/k3s:' + version.replace('+', '-'), 'server', '--node-name=ci-controller',
               '--disable=traefik,servicelb,local-storage,metrics-server',
               '--flannel-backend=none', '--disable-network-policy', '--disable-kube-proxy')
        containers.append(k3s)

        def kube(*args, input=None):
            # The container contains the server multicall binary; invoke its kubectl
            # symlink directly (the downloadable host binary has a different wrapper).
            return subprocess.check_output(['docker', 'exec', '-i', k3s, '/bin/kubectl',
                                            '--kubeconfig=/etc/rancher/k3s/k3s.yaml',
                                            '--request-timeout=10s', *args],
                                           input=input, text=True, stderr=subprocess.PIPE)

        def node_change(node, ip, create=False):
            if create:
                kube('create', '-f', '-', input=json.dumps({'apiVersion': 'v1', 'kind': 'Node',
                                                          'metadata': {'name': node}}))
            status = {'status': {'addresses': [{'type': 'InternalIP', 'address': ip},
                                               {'type': 'Hostname', 'address': node}]}}
            kube('patch', 'node', node, '--subresource=status', '--type=merge', '-p', json.dumps(status))

        def sync_node_hosts(expected, absent=()):
            # Kubernetes normally projects this key. Copy the real controller output into
            # the Docker mount so the upstream DNS process is tested without a second CNI.
            def synced():
                cm = json.loads(kube('-n', 'kube-system', 'get', 'configmap', 'coredns', '-o', 'json'))
                hosts = cm['data'].get('NodeHosts', '')
                records = {host: fields[0] for line in hosts.splitlines()
                           if len(fields := line.split()) > 1 for host in fields[1:]}
                assert all(records.get(node) == ip for node, ip in expected.items()), records
                assert not any(node in records for node in absent), records
                path = node_directory / 'NodeHosts.new'
                path.write_text(hosts)
                path.chmod(0o644)
                os.replace(path, node_directory / 'NodeHosts')
            wait_for(synced, 'native k3s NodeHosts reconciliation', 180)

        wait_for(lambda: kube('-n', 'kube-system', 'get', 'configmap', 'coredns'), 'disposable k3s API', 180)
        nodes = {'worker-east': '192.0.2.11', 'gpu-west': '192.0.2.12',
                 'build-39': '192.0.2.13', 'spare-104': '192.0.2.14'}
        for node, ip in nodes.items():
            node_change(node, ip, create=True)
        sync_node_hosts(nodes)
        upstream_file = root / 'upstream.Corefile'
        upstream_file.write_text(''.join(
            f'''.:{port} {{
    log
    template IN A {{
        answer "{{{{ .Name }}}} 0 IN A {answer}"
    }}
    template ANY ANY {{
        rcode NOERROR
    }}
}}
''' for port, answer in [(1053, '203.0.113.10'), (1054, '203.0.113.20')]))
        upstream_file.chmod(0o644)

        def start(container_name, mount, publish=(), extra=()):
            capabilities = pod['containers'][0]['securityContext']['capabilities']
            assert capabilities['drop'] == ['ALL']
            assert capabilities['add'] == ['NET_BIND_SERVICE']
            docker('run', '--detach', '--name', container_name, '--network', name,
                   '--user', f'{uid}:{uid}', '--read-only', '--cap-drop=ALL',
                   '--cap-add=NET_BIND_SERVICE',
                   '--security-opt=no-new-privileges', '--volume', mount,
                   *publish, *extra, image, '-conf', '/etc/coredns/Corefile')
            containers.append(container_name)
            return docker('inspect', '--format', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', container_name)

        upstream = start(name + '-upstream', f'{upstream_file}:/etc/coredns/Corefile:ro')
        values = dict(settings, DNS_UPSTREAMS=upstream + ':1053')

        def write_config(current):
            for filename in ('Corefile', 'internal.db', 'empty.db'):
                text = (ROOT / 'infrastructure/dns' / filename).read_text()
                for key, value in current.items():
                    text = text.replace('${' + key + '}', value)
                assert '${' not in text
                # Atomic replacement, as with a projected ConfigMap update.
                temporary = config / (filename + '.new')
                temporary.write_text(text)
                temporary.chmod(0o644)
                os.replace(temporary, config / filename)

        write_config(values)
        server = name + '-server'
        start(server, f'{config}:/etc/coredns:ro',
              ('--publish', '127.0.0.1::1053/udp', '--publish', '127.0.0.1::1053/tcp'),
              ('--volume', f'{node_directory}:/etc/k3s-coredns:ro'))
        ports = {protocol: int(docker('port', server, '1053/' + protocol).rsplit(':', 1)[1])
                 for protocol in ('udp', 'tcp')}

        def query(host, qtype='A', protocol='udp'):
            request = dns.message.make_query(host, qtype)
            return getattr(dns.query, protocol)(request, '127.0.0.1', port=ports[protocol], timeout=2)

        def check(host, expected=None, qtype='A', protocol='udp', rcode=dns.rcode.NOERROR):
            answer = query(host, qtype, protocol)
            assert answer.rcode() == rcode, answer.to_text()
            assert answer.question[0].name.to_text().lower() == host.lower().rstrip('.') + '.', answer.to_text()
            assert all(rrset.name.to_text().lower() == host.lower().rstrip('.') + '.'
                       for rrset in answer.answer), answer.to_text()
            addresses = [item.to_text() for rrset in answer.answer for item in rrset
                         if rrset.rdtype == dns.rdatatype.A]
            assert addresses == ([] if expected is None else [expected]), answer.to_text()
            if expected is None:
                assert not answer.answer, answer.to_text()
            if rcode == dns.rcode.NXDOMAIN and '.hosts.' in host:
                soa = [rrset for rrset in answer.authority if rrset.rdtype == dns.rdatatype.SOA]
                zone = 'hosts.' + host.split('.hosts.', 1)[1].rstrip('.') + '.'
                assert len(soa) == 1 and soa[0].name.to_text() == zone, answer.to_text()

        wait_for(lambda: check('worker-east.hosts.internal', nodes['worker-east']), 'CoreDNS startup')
        for protocol in ('udp', 'tcp'):
            check('hosts.internal', protocol=protocol)
            soa = query('hosts.internal', 'SOA', protocol)
            assert soa.rcode() == dns.rcode.NOERROR and soa.answer[0].name.to_text() == 'hosts.internal.', soa.to_text()
            for node, ip in nodes.items():
                check(node + '.hosts.internal', ip, protocol=protocol)
                for qtype in ('AAAA', 'TXT', 'HTTPS'):
                    check(node + '.hosts.internal', qtype=qtype, protocol=protocol)
            for host in ('foo.internal', 'longhorn.admin.internal', 'foo.staging.internal',
                         'foo-a7c92e.test.internal', 'foo-b41d08.test.internal', 'FOO.INTERNAL'):
                check(host, settings['EDGE_IP'], protocol=protocol)
                for qtype in ('AAAA', 'TXT', 'HTTPS'):
                    check(host, qtype=qtype, protocol=protocol)
            check('dns.admin.internal', settings['DNS_IP'], protocol=protocol)
            for qtype in ('A', 'AAAA', 'TXT'):
                check('missing.hosts.internal', qtype=qtype, protocol=protocol, rcode=dns.rcode.NXDOMAIN)
            check('deep.missing.hosts.internal', protocol=protocol, rcode=dns.rcode.NXDOMAIN)
            check('kubernetes.default.svc.cluster.local', protocol=protocol, rcode=dns.rcode.NXDOMAIN)
            check('forward-check.example', '203.0.113.10', protocol=protocol)
        upstream_log = docker('logs', name + '-upstream')
        assert 'forward-check.example.' in upstream_log
        assert '.internal.' not in upstream_log and '.cluster.local.' not in upstream_log, upstream_log
        print('UDP/TCP, all internal groups, machine records, NODATA/NXDOMAIN and upstream forwarding passed.', flush=True)

        # Real Kubernetes node status changes, additions and deletions; no fixed inventory.
        nodes['gpu-west'] = '192.0.2.122'
        node_change('gpu-west', nodes['gpu-west'])
        nodes['arriving-205'] = '192.0.2.205'
        node_change('arriving-205', nodes['arriving-205'], create=True)
        kube('delete', 'node', 'spare-104', '--wait=false')
        nodes.pop('spare-104')
        sync_node_hosts(nodes, absent=['spare-104'])
        wait_for(lambda: check('gpu-west.hosts.internal', nodes['gpu-west']), 'DHCP address update', 180)
        wait_for(lambda: check('arriving-205.hosts.internal', nodes['arriving-205']), 'new node DNS')
        wait_for(lambda: check('spare-104.hosts.internal', rcode=dns.rcode.NXDOMAIN), 'removed node DNS')
        print('Native k3s node additions, IP updates and removals propagated to DNS.', flush=True)
        # Same SOA serial and same pod: test the actual supported hot-reload behavior.
        values.update(EDGE_IP='192.0.2.240', DNS_UPSTREAMS=upstream + ':1054')
        write_config(values)
        wait_for(lambda: check('reload-check.test.internal', values['EDGE_IP']), 'wildcard-zone reload')
        wait_for(lambda: check('second-upstream.example', '203.0.113.20'), 'Corefile upstream reload')
        check('missing.hosts.internal', rcode=dns.rcode.NXDOMAIN)
        assert docker('inspect', '--format', '{{.RestartCount}}', server) == '0'
        assert docker('inspect', '--format', '{{.Config.User}}', server) == f'{uid}:{uid}'
        # A second cluster's suffix must work with the same manifests and arbitrary nodes.
        custom = config / 'custom'
        custom.mkdir(mode=0o755)
        (custom / 'manual.hosts').write_text('192.0.2.99 printer\n')
        (custom / 'neighbors.server').write_text(
            'neighbors.factory.internal:1053 {\n    forward . ' + upstream + ':1053\n}\n')
        values.update(INTERNAL_DOMAIN='factory.internal')
        write_config(values)
        wait_for(lambda: check('arriving-205.hosts.factory.internal', nodes['arriving-205']), 'second cluster host suffix')
        check('longhorn.admin.factory.internal', values['EDGE_IP'])
        check('new-test-4.test.factory.internal', values['EDGE_IP'])
        check('missing.hosts.factory.internal', rcode=dns.rcode.NXDOMAIN)
        check('printer.hosts.factory.internal', '192.0.2.99')
        check('app.neighbors.factory.internal', '203.0.113.10')
        print('Wildcard/upstream reloads and a second cluster domain passed without a restart, running non-root.', flush=True)
except BaseException:
    for container in containers:
        print(docker('logs', container))
    raise
finally:
    for container in reversed(containers):
        subprocess.run(['docker', 'rm', '--force', '--volumes', container], check=False, stdout=subprocess.DEVNULL)
    subprocess.run(['docker', 'network', 'rm', name], check=False, stdout=subprocess.DEVNULL)
