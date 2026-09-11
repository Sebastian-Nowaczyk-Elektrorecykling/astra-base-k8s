#!/usr/bin/env python3
"""Run upstream CoreDNS in disposable Docker containers; no cluster access."""
import os
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

ROOT = pathlib.Path(__file__).resolve().parents[1]
settings = yaml.safe_load((ROOT / 'clusters/laptops/settings.yaml').read_text())['data']
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
    while time.monotonic() < deadline:
        try:
            test()
            return
        except (AssertionError, OSError, dns.exception.DNSException):
            time.sleep(2)
    raise AssertionError('Timed out waiting for ' + description)


name = 'elektro-dns-' + uuid.uuid4().hex[:10]
containers = []
docker('network', 'create', name)
try:
    with tempfile.TemporaryDirectory(prefix='elektro-dns-') as tmp:
        root = pathlib.Path(tmp)
        config = root / 'config'
        config.mkdir(mode=0o755)
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

        def start(container_name, mount, publish=()):
            capabilities = pod['containers'][0]['securityContext']['capabilities']
            assert capabilities['drop'] == ['ALL']
            assert capabilities['add'] == ['NET_BIND_SERVICE']
            docker('run', '--detach', '--name', container_name, '--network', name,
                   '--user', f'{uid}:{uid}', '--read-only', '--cap-drop=ALL',
                   '--cap-add=NET_BIND_SERVICE',
                   '--security-opt=no-new-privileges', '--volume', mount,
                   *publish, image, '-conf', '/etc/coredns/Corefile')
            containers.append(container_name)
            return docker('inspect', '--format', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', container_name)

        upstream = start(name + '-upstream', f'{upstream_file}:/etc/coredns/Corefile:ro')
        values = dict(settings, DNS_UPSTREAMS=upstream + ':1053')

        def write_config(current):
            for filename in ('Corefile', 'internal.db', 'hosts.db'):
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
              ('--publish', '127.0.0.1::1053/udp', '--publish', '127.0.0.1::1053/tcp'))
        ports = {protocol: int(docker('port', server, '1053/' + protocol).rsplit(':', 1)[1])
                 for protocol in ('udp', 'tcp')}

        def query(host, qtype='A', protocol='udp'):
            request = dns.message.make_query(host, qtype)
            return getattr(dns.query, protocol)(request, '127.0.0.1', port=ports[protocol], timeout=2)

        def check(host, expected=None, qtype='A', protocol='udp', rcode=dns.rcode.NOERROR):
            answer = query(host, qtype, protocol)
            assert answer.rcode() == rcode, answer.to_text()
            addresses = [item.to_text() for rrset in answer.answer for item in rrset
                         if rrset.rdtype == dns.rdatatype.A]
            assert addresses == ([] if expected is None else [expected]), answer.to_text()
            if expected is None:
                assert not answer.answer, answer.to_text()

        wait_for(lambda: check('k8s1.hosts.internal', settings['K8S1_IP']), 'CoreDNS startup')
        for protocol in ('udp', 'tcp'):
            for number in (1, 2, 3):
                check(f'k8s{number}.hosts.internal', settings[f'K8S{number}_IP'], protocol=protocol)
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

        # Same SOA serial and same pod: test the actual supported hot-reload behavior.
        values.update(K8S2_IP='192.0.2.122', EDGE_IP='192.0.2.240', DNS_UPSTREAMS=upstream + ':1054')
        write_config(values)
        wait_for(lambda: check('k8s2.hosts.internal', values['K8S2_IP']), 'host-zone reload', 180)
        wait_for(lambda: check('reload-check.test.internal', values['EDGE_IP']), 'wildcard-zone reload')
        wait_for(lambda: check('second-upstream.example', '203.0.113.20'), 'Corefile upstream reload')
        check('missing.hosts.internal', rcode=dns.rcode.NXDOMAIN)
        assert docker('inspect', '--format', '{{.RestartCount}}', server) == '0'
        assert docker('inspect', '--format', '{{.Config.User}}', server) == f'{uid}:{uid}'
        print('Host/wildcard records and changed upstream reloaded without a restart, running non-root.', flush=True)
except BaseException:
    for container in containers:
        print(docker('logs', container))
    raise
finally:
    for container in reversed(containers):
        subprocess.run(['docker', 'rm', '--force', container], check=False, stdout=subprocess.DEVNULL)
    subprocess.run(['docker', 'network', 'rm', name], check=False, stdout=subprocess.DEVNULL)
