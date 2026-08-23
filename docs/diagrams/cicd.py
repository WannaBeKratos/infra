"""Render docs/diagrams/cicd.png.

    pip install diagrams        # needs Graphviz's `dot` on PATH
    python docs/diagrams/cicd.py

The life of one change, left to right. The upper lane is a change to this
repository (.github/workflows/terraform.yml); the lower lane is a change to an
application repository, whose own ci.yml calls
.github/workflows/deploy-application.yml here as a reusable workflow.
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.generic.os import Ubuntu
from diagrams.k8s.compute import Deploy
from diagrams.k8s.network import Service
from diagrams.onprem.container import Docker
from diagrams.onprem.iac import Terraform
from diagrams.onprem.security import Vault
from diagrams.onprem.vcs import Git, Github
from diagrams.programming.flowchart import Action, Decision, StartEnd

OUTPUT = Path(__file__).with_name("cicd")

GRAPH_ATTR = {
    "fontsize": "24",
    "labelloc": "t",
    "pad": "0.6",
    "nodesep": "0.4",
    "ranksep": "1.0",
    "splines": "spline",
}
CLUSTER_ATTR = {"fontsize": "15", "margin": "18"}
NODE_ATTR = {"fontsize": "12"}

PASS = Edge(color="darkgreen")
FAIL = Edge(color="firebrick", style="dashed")
MANUAL = Edge(color="darkorange", style="bold")

with Diagram(
    "Life of a change: gates in CI, applies by hand, deploys blue/green",
    filename=str(OUTPUT),
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
    node_attr=NODE_ATTR,
):
    commit = Git("commit on\ndevelopment")

    # ---------------------------------------------------------------- infra --
    with Cluster("Infrastructure change — this repo", graph_attr=CLUSTER_ATTR):
        infra_push = Github("push / pull request")

        with Cluster("terraform.yml — gates", graph_attr=CLUSTER_ATTR):
            fmt = Action("terraform fmt\n-check -recursive")
            validate = Action("init -backend=false\nterraform validate")
            checkov = Action("checkov\n.checkov.yaml")
            gitleaks = Action("gitleaks\nfull history")
            plan_dev = Action("plan (dev)\nalways")
            plan_prod = Action("plan (production)\nonly when main is at stake")

            # fmt and validate are steps of one job; checkov and gitleaks are
            # jobs of their own, so they start in parallel.
            fmt >> PASS >> validate >> PASS >> plan_dev >> PASS >> plan_prod

        merge = Decision("review\nand merge to main")

        with Cluster("Apply — manual, by policy", graph_attr=CLUSTER_ATTR):
            wsl = Ubuntu("WSL\nTF_DATA_DIR=.terraform-linux")
            apply = Terraform("workspace select\nplan -out=tfplan\napply tfplan")
            wsl >> MANUAL >> apply

        infra_push >> PASS >> fmt
        infra_push >> PASS >> checkov
        infra_push >> PASS >> gitleaks
        plan_prod >> PASS >> merge
        checkov >> PASS >> merge
        gitleaks >> PASS >> merge
        merge >> MANUAL >> wsl

    # ------------------------------------------------------------ application --
    with Cluster("Application change — applim, ppe, ...", graph_attr=CLUSTER_ATTR):
        app_push = Github("push to\nmain / development")

        with Cluster("app ci.yml — gates", graph_attr=CLUSTER_ATTR):
            unit = Action("format, build,\nunit tests")
            e2e = Action("end to end\nin a browser")
            smoke = Docker("image builds\nand answers /healthz")

            unit >> PASS >> e2e
            unit >> PASS >> smoke

        gate = Decision("KUBERNETES_DEPLOY_ENABLED\nand branch is main\nor development")

        with Cluster("deploy-application.yml — reusable workflow", graph_attr=CLUSTER_ATTR):
            build = Docker("docker build\npush ghcr.io/<owner>/<app>")
            tunnel = Vault("cloudflared access tcp\nAccess service token\n-> 127.0.0.1:6443")
            apply_manifest = Action(
                "envsubst on kubernetes/application.yaml\n"
                "APP_NAME REPLICAS IMAGE PORT\nHEALTH_PATH PROMOTE_SECONDS\nkubectl apply -f -"
            )
            build >> PASS >> tunnel >> PASS >> apply_manifest

        with Cluster("Argo Rollouts — blue/green", graph_attr=CLUSTER_ATTR):
            preview = Service("preview.<host>\nAccess-gated soak\n600 s prod / 30 s test")
            rollout = Deploy("Rollout\nnew ReplicaSet")
            active = Service("active Service\nswitched atomically")

            rollout >> PASS >> preview
            preview >> Edge(color="darkgreen", label="autoPromotionSeconds") >> active

        app_push >> PASS >> unit
        e2e >> PASS >> gate
        smoke >> PASS >> gate
        gate >> PASS >> build
        apply_manifest >> PASS >> rollout

    commit >> Edge(style="bold") >> infra_push
    commit >> Edge(style="bold") >> app_push

    live = StartEnd("Serving\non the tunnel")
    active >> PASS >> live

    # The two ways a change stops.
    preview >> Edge(color="firebrick", style="dashed", label="probes fail or\nrollouts abort:\nstable keeps serving") >> rollout
    gate >> Edge(color="firebrick", style="dashed", label="variable unset:\njob skipped") >> live

print(f"wrote {OUTPUT.with_suffix('.png')}")
