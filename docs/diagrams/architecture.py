"""Render docs/diagrams/architecture.png.

    pip install diagrams        # needs Graphviz's `dot` on PATH
    python docs/diagrams/architecture.py

Everything drawn here exists in this repository: the node shapes come from
modules/cluster, the tunnel and Access objects from modules/edge, the R2 buckets
from bootstrap/main.tf and backups.tf, the in-cluster workloads from rollouts.tf,
services.tf and kubernetes/application.yaml.

Reading order: who talks to the platform (top), the Cloudflare edge that is the
only door (middle), the clusters behind it, and the R2 buckets everything
persists to. Production is drawn in full; dev is the same shape smaller, so it
is drawn abbreviated rather than repeated.
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.generic.os import Ubuntu
from diagrams.generic.storage import Storage
from diagrams.k8s.compute import Deploy, Pod
from diagrams.k8s.infra import Master, Node
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users
from diagrams.onprem.container import Docker
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.iac import Terraform
from diagrams.onprem.inmemory import Redis
from diagrams.onprem.security import Vault
from diagrams.onprem.vcs import Github
from diagrams.saas.cdn import Cloudflare

OUTPUT = Path(__file__).with_name("architecture")

GRAPH_ATTR = {
    "fontsize": "24",
    "labelloc": "t",
    "pad": "0.5",
    "nodesep": "0.6",
    "ranksep": "1.0",
    "splines": "spline",
    "compound": "true",
}
CLUSTER_ATTR = {"fontsize": "15", "margin": "16"}

TRAFFIC = {"color": "darkgreen", "style": "bold"}
CONTROL = {"color": "darkorange"}
IMAGE = {"color": "purple", "style": "dashed"}
BACKUP = {"color": "steelblue", "style": "dotted"}

with Diagram(
    "Hetzner k3s platform: two clusters, one Cloudflare edge, no open inbound ports",
    filename=str(OUTPUT),
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
):
    visitors = Users("Visitors")

    with Cluster("Operator workstation", graph_attr=CLUSTER_ATTR):
        wsl = Ubuntu("WSL")
        tf = Terraform("terraform apply\nmanual, by policy")
        wsl >> tf

    with Cluster("GitHub", graph_attr=CLUSTER_ATTR):
        repos = Github("app repos + this one")
        actions = GithubActions("Actions\nplan gates · deploy workflow")
        ghcr = Docker("GHCR images")
        repos >> actions
        actions >> Edge(label="build + push", **IMAGE) >> ghcr

    with Cluster("Cloudflare — the only way in", graph_attr=CLUSTER_ATTR):
        dns = Cloudflare("DNS\nproxied CNAME per hostname")
        access = Vault("Zero Trust Access\ntest.* + kube-API gates\n/mcp + /oauth bypass")
        tunnel = Cloudflare("Tunnel edge\ncloudflared dials out, nothing dials in")
        dns >> Edge(**TRAFFIC) >> access >> Edge(**TRAFFIC) >> tunnel

    with Cluster("Hetzner · projects-production (workspace production)", graph_attr=CLUSTER_ATTR):
        with Cluster("control-plane · cx23", graph_attr=CLUSTER_ATTR):
            prod_cp = Master("k3s server\nkube-API :6443, IP-restricted")

        with Cluster("agent nodes · 2 × cx23 (+ autoscale 0–2)", graph_attr=CLUSTER_ATTR):
            prod_tunnel = Pod("cloudflared")
            prod_argo = Argocd("argo-rollouts")
            with Cluster("namespace applim", graph_attr=CLUSTER_ATTR):
                prod_app = Deploy("Rollout blue/green\napp + sweeper + litestream")
                prod_redis = Redis("redis\ncache + vectors")
                prod_app - Edge(style="invis") - prod_redis

    with Cluster("Hetzner · projects-dev (workspace dev, serves test.*)", graph_attr=CLUSTER_ATTR):
        with Cluster("1 control-plane + 1 agent · cx23", graph_attr=CLUSTER_ATTR):
            dev_stack = Node("same shape as production\napplim-test namespace, 30 s promote")

    with Cluster("Cloudflare R2 (S3-compatible)", graph_attr=CLUSTER_ATTR):
        r2_state = Storage("terraform state\nenv/<workspace>")
        r2_feed = Storage("feed backups\napplim-feed-<env>")

    # Visitor traffic: edge to the in-cluster tunnel pods, then the Services.
    visitors >> Edge(**TRAFFIC) >> dns
    tunnel >> Edge(**TRAFFIC) >> prod_tunnel >> Edge(**TRAFFIC) >> prod_app
    tunnel >> Edge(**TRAFFIC) >> dev_stack

    # Control: the operator applies against the cloud APIs and both kube-APIs;
    # CI reaches the kube-APIs only through the Access-gated tunnel.
    tf >> Edge(label="hcloud + cloudflare APIs", **CONTROL) >> dns
    tf >> Edge(**CONTROL) >> prod_cp
    actions >> Edge(label="plan / kubectl apply\nservice token", **CONTROL) >> access

    # Images and backups.
    ghcr >> Edge(label="imagePullSecret", **IMAGE) >> prod_app
    prod_app >> Edge(label="litestream, continuous", **BACKUP) >> r2_feed
    tf >> Edge(label="remote state", **BACKUP) >> r2_state

print(f"wrote {OUTPUT}.png")
