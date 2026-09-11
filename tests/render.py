#!/usr/bin/env python3
"""Repository/Helm validation harness. Never deployed to the cluster."""
import argparse
import ipaddress
import json
import pathlib
import subprocess
import urllib.request

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f"Duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def read(path):
    return [d for d in yaml.load_all(path.read_text(), Loader=UniqueLoader) if d is not None]


def write(path, documents):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump_all(documents, sort_keys=False))


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True)


def static():
    files = [p for folder in ("infrastructure", "clusters", "examples", "bootstrap")
             for p in (ROOT / folder).rglob("*.yaml")]
    documents = [d for p in files for d in read(p)]
    for p in ROOT.rglob("kustomization.yaml"):
        if ".cache" in p.parts or "rendered" in p.parts:
            continue
        for resource in read(p)[0].get("resources", []):
            assert (p.parent / resource).exists(), (p, resource)
    flux_base = ROOT / "clusters/laptops/flux-system"
    assert {"gotk-components.yaml", "gotk-sync.yaml"}.issubset(
        read(flux_base / "kustomization.yaml")[0]["resources"]), "Flux bootstrap must include controllers and sync resources"
    assert any(d.get("kind") == "Deployment" for d in read(flux_base / "gotk-components.yaml"))
    phases = read(ROOT / "clusters/laptops/reconciliation.yaml")
    by_name = {p["metadata"]["name"]: p for p in phases}
    def visit(name, trail):
        assert name not in trail, f"Dependency cycle: {trail + [name]}"
        for dep in by_name[name]["spec"].get("dependsOn", []):
            assert dep["name"] in by_name
            visit(dep["name"], trail + [name])
    for name in by_name:
        visit(name, [])
    classes = read(ROOT / "infrastructure/storage/classes.yaml")
    assert {c["metadata"]["name"]: c["parameters"]["numberOfReplicas"] for c in classes} == {
        "longhorn": "1", "longhorn-3": "3", "longhorn-cnpg": "1"}
    assert all(c["reclaimPolicy"] == "Retain" and c["parameters"]["dataEngine"] == "v1" for c in classes)
    sp = read(ROOT / "infrastructure/access/resources.yaml")[0]["spec"]
    realm_config = read(ROOT / "infrastructure/identity/resources.yaml")[0]["data"]
    realm = json.loads(realm_config["elektro-realm.json"])
    assert realm["realm"] == "elektro"
    client = next(c for c in realm["clients"] if c["clientId"] == sp["oidc"]["clientID"])
    assert client["clientId"] == "elektro-edge"
    assert sp["oidc"]["provider"]["issuer"].endswith("/realms/elektro")
    assert all(p["issuer"] == sp["oidc"]["provider"]["issuer"] and p["audiences"] == [client["clientId"]]
               for p in sp["jwt"]["providers"])
    assert sp["extAuth"]["failOpen"] is False and sp["oidc"] and sp["jwt"]
    assert "cookieDomain" not in sp["oidc"]
    settings = read(ROOT / "clusters/laptops/settings.yaml")[0]["data"]
    assert "BASE_DOMAIN" not in settings
    dns_ip = ipaddress.IPv4Address(settings['DNS_IP'])
    assert ipaddress.IPv4Address(settings['LB_START']) <= dns_ip <= ipaddress.IPv4Address(settings['LB_STOP'])
    assert str(dns_ip) not in [settings['EDGE_IP'], settings['PUBLIC_EDGE_IP'], settings['API_HOST']]
    clients = ipaddress.IPv4Network(settings['DNS_CLIENT_CIDR'])
    assert clients.prefixlen > 0 and not clients.is_multicast, 'DNS must not be an unrestricted resolver'
    assert settings['DNS_UPSTREAMS'].split(), 'Configure at least one upstream'
    for upstream in settings['DNS_UPSTREAMS'].split():
        parts = upstream.split(':')
        address = ipaddress.IPv4Address(parts[0])
        assert not (address.is_loopback or address.is_unspecified or address.is_multicast)
        assert address != dns_ip, 'DNS cannot forward to itself'
        assert len(parts) == 1 or (len(parts) == 2 and 0 < int(parts[1]) < 65536)
    for number in (1, 2, 3):
        assert ipaddress.IPv4Address(settings[f'K8S{number}_IP']) != dns_ip
    assert '*' not in (ROOT / 'infrastructure/dns/hosts.db').read_text()
    assert by_name['dns']['spec']['dependsOn'] == [{'name': 'network'}]
    assert by_name['cluster-dns']['spec']['dependsOn'] == [{'name': 'dns'}]
    dns_pod = read(ROOT / 'infrastructure/dns/resources.yaml')[0]['spec']['template']['spec']
    assert dns_pod['automountServiceAccountToken'] is False
    assert dns_pod['dnsPolicy'] == 'Default'
    assert dns_pod['containers'][0]['image'] == 'coredns/coredns:1.14.7'
    private_gateway = read(ROOT / "infrastructure/edge/resources.yaml")[-1]
    listener_hosts = {l["name"]: l["hostname"] for l in private_gateway["spec"]["listeners"]}
    assert listener_hosts == {"identity": "keycloak.admin.internal", "admin": "*.admin.internal",
                              "test": "*.test.internal", "staging": "*.staging.internal", "apps": "*.internal"}
    assert {t["sectionName"] for t in sp["targetRefs"]} == {"admin", "test", "staging", "apps"}
    assert set(read(ROOT / "infrastructure/certificates/resources.yaml")[-1]["spec"]["dnsNames"]) == {
        "*.internal", "*.admin.internal", "*.test.internal", "*.staging.internal"}
    assert client["redirectUris"] == ["https://longhorn.admin.internal/oauth2/callback"]
    assert not any("public-exposure" in p["spec"]["path"] for p in phases), "Public exposure must remain opt-in"
    for p in (ROOT / "infrastructure").rglob("*.yaml"):
        assert not any(d.get("kind") == "Gateway" and d["metadata"]["name"] == "public" for d in read(p))
    assert by_name["routes"]["spec"]["dependsOn"] == [{"name": "access"}]
    assert by_name["access"]["spec"]["healthCheckExprs"]
    assert read(ROOT / "infrastructure/controllers/releases.yaml")[0]["spec"]["values"]["persistence"]["createStorageClass"] is False
    for d in documents:
        if isinstance(d, dict) and d.get("kind") == "HelmRelease":
            version = d["spec"]["chart"]["spec"]["version"]
            assert version and not any(c in version for c in "*><~^"), version
        if isinstance(d, dict) and d.get("kind") == "Secret":
            assert "sops" in d or all(str(v).startswith("ENC[") for v in d.get("data", {}).values()), "Plaintext Secret"
    json.loads((ROOT / "infrastructure/access/model.json").read_text())
    print(f"Static checks passed: {len(files)} YAML files; dependency graph and access/storage invariants.")


def render():
    settings = read(ROOT / "clusters/laptops/settings.yaml")[0]["data"]
    # Optional examples also get explicit sample values during validation.
    settings.update(API_VIP="192.168.50.10", API_VIP_INTERFACE="eth0")
    manifests = []
    for p in sorted((ROOT / "infrastructure").rglob("kustomization.yaml")):
        text = run("kubectl", "kustomize", str(p.parent))
        for key, value in settings.items():
            text = text.replace("${" + key + "}", value)
        ds = list(yaml.safe_load_all(text))
        write(ROOT / "rendered" / (p.parent.relative_to(ROOT).as_posix().replace("/", "-") + ".yaml"), ds)
        manifests.extend(d for d in ds if d)
    sources = {d["metadata"]["name"]: d["spec"] for d in manifests if d.get("kind") == "HelmRepository"}
    chart_objects = []
    for hr in [d for d in manifests if d.get("kind") == "HelmRelease"]:
        spec = hr["spec"]
        chart = spec["chart"]["spec"]
        name = hr["metadata"]["name"]
        source = sources[chart["sourceRef"]["name"]]
        target = ROOT / ".cache/charts" / name
        values = dict(spec.get("values", {}))
        if name == "cilium":
            values = {**read(ROOT / "infrastructure/cilium/values.yaml")[0], **values}
        value_path = ROOT / ".cache/values" / (name + ".yaml")
        write(value_path, [values])
        args = ["helm", "pull"]
        if source.get("type") == "oci":
            args += [source["url"] + "/" + chart["chart"]]
        else:
            args += [chart["chart"], "--repo", source["url"]]
        args += ["--version", chart["version"], "--untar", "--untardir", str(target)]
        run(*args)
        chart_path = target / chart["chart"]
        run("helm", "lint", str(chart_path), "--values", str(value_path), "--namespace", hr["metadata"]["namespace"], "--kube-version", "1.36.4")
        text = run("helm", "template", name, str(chart_path), "--namespace", hr["metadata"]["namespace"],
                   "--values", str(value_path), "--kube-version", "1.36.4", "--include-crds")
        objs = [d for d in yaml.safe_load_all(text) if d]
        if name == "cilium":
            # Verify the address reaches actual pods, including API-dependent init containers.
            workloads = [d for d in objs if (d.get("kind"), d["metadata"]["name"]) in {
                ("DaemonSet", "cilium"), ("Deployment", "cilium-operator")}]
            assert len(workloads) == 2
            checked = set()
            for workload in workloads:
                pod = workload["spec"]["template"]["spec"]
                for container in pod["containers"] + pod.get("initContainers", []):
                    env = {e["name"]: e.get("value") for e in container.get("env", [])}
                    if "KUBERNETES_SERVICE_HOST" in env:
                        assert env["KUBERNETES_SERVICE_HOST"] == settings["API_HOST"], container["name"]
                        assert str(env["KUBERNETES_SERVICE_PORT"]) == "6443", container["name"]
                        checked.add((workload["metadata"]["name"], container["name"]))
            assert {("cilium", "cilium-agent"), ("cilium-operator", "cilium-operator")} <= checked
            print(f"Verified Cilium API address in {len(checked)} agent/operator/init containers")
        write(ROOT / "rendered/charts" / (name + ".yaml"), objs)
        chart_objects.extend(objs)
        print(f"Rendered {name}: chart {chart['version']}")
    # Confirm explicit standalone image tags exist without running application containers.
    for image in sorted({settings["PG_IMAGE"], "quay.io/keycloak/keycloak:26.7.3", "quay.io/kuadrant/authorino:v0.26.3"}):
        run("docker", "manifest", "inspect", image)
        print(f"Verified image manifest: {image}")
    # CRDs embedded in the Cilium binary and the standalone Authorino distribution.
    extra_urls = ["https://github.com/fluxcd/flux2/releases/download/v2.9.5/install.yaml",
                  "https://raw.githubusercontent.com/Kuadrant/authorino/v0.26.3/install/crd/authorino.kuadrant.io_authconfigs.yaml"]
    for version, names in {"v2": ["ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies", "ciliumloadbalancerippools"],
                           "v2alpha1": ["ciliuml2announcementpolicies"]}.items():
        extra_urls.extend(f"https://raw.githubusercontent.com/cilium/cilium/v1.20.1/pkg/k8s/apis/cilium.io/client/crds/{version}/{name}.yaml" for name in names)
    for url in extra_urls:
        with urllib.request.urlopen(url, timeout=60) as response:
            chart_objects.extend(d for d in yaml.safe_load_all(response.read()) if d)
    crds = {d["metadata"]["name"]: d for d in chart_objects if d.get("kind") == "CustomResourceDefinition"}
    write(ROOT / "rendered/crds.yaml", list(crds.values()))
    write(ROOT / "rendered/namespaces.yaml", [d for d in manifests if d.get("kind") == "Namespace"])
    print(f"Rendered {len(manifests)} infrastructure resources and {len(crds)} upstream CRDs.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--charts", action="store_true")
    args = parser.parse_args()
    static()
    if args.charts:
        render()
