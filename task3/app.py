import os
import shlex
import subprocess

from flask import Flask

app = Flask(__name__)

KUBECTL = shlex.split(os.environ.get("KUBECTL", "microk8s kubectl"))
NAMESPACE = os.environ.get("NAMESPACE", "task3")
DEPLOYMENT = os.environ.get("DEPLOYMENT", "nginx")


def kubectl(*args):
    return subprocess.run(
        [*KUBECTL, "-n", NAMESPACE, *args],
        capture_output=True,
        text=True,
    )


@app.route("/health")
def health():
    return "ok\n"


@app.route("/spin-up")
def spin_up():
    scaled = kubectl("scale", f"deployment/{DEPLOYMENT}", "--replicas=1")
    ready = kubectl("rollout", "status", f"deployment/{DEPLOYMENT}", "--timeout=180s")
    body = scaled.stdout + scaled.stderr + ready.stdout + ready.stderr
    if scaled.returncode != 0 or ready.returncode != 0:
        return body, 500
    return body or "spun up\n"


@app.route("/spin-down")
def spin_down():
    scaled = kubectl("scale", f"deployment/{DEPLOYMENT}", "--replicas=0")
    if scaled.returncode != 0:
        return scaled.stdout + scaled.stderr, 500
    waited = kubectl(
        "wait",
        "--for=delete",
        "pod",
        "-l",
        "app=nginx",
        "--timeout=120s",
    )
    body = scaled.stdout + scaled.stderr + waited.stdout + waited.stderr
    if waited.returncode != 0 and "no matching resources" not in body.lower():
        return body, 500
    return body or "spun down\n"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8081")))
