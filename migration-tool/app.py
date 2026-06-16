"""Flask API for the migration orchestrator."""

import os

from flask import Flask, jsonify, render_template, request

from orchestrator import Orchestrator

app = Flask(__name__)
orchestrator = Orchestrator(
    config_path=os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yaml")
)


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/vms", methods=["GET"])
def api_list_vms():
    return jsonify(orchestrator.list_vms())


@app.route("/api/vms/<vm_name>", methods=["GET"])
def api_get_vm(vm_name: str):
    vm = orchestrator.get_vm(vm_name)
    if not vm:
        return jsonify({"error": "VM not found"}), 404
    vm["logs"] = orchestrator.get_vm_logs(vm_name)
    return jsonify(vm)


@app.route("/api/import", methods=["POST"])
def api_import():
    if "file" in request.files and request.files["file"].filename:
        content = request.files["file"].read().decode("utf-8-sig")
    elif request.data:
        content = request.data.decode("utf-8-sig")
    elif request.is_json and request.json.get("csv"):
        content = request.json["csv"]
    else:
        return jsonify({"success": False, "error": "No CSV content provided"}), 400

    result = orchestrator.import_csv(content)
    status = 200 if result.get("success") else 400
    return jsonify(result), status


@app.route("/api/start", methods=["POST"])
def api_start():
    result = orchestrator.start()
    status = 200 if result.get("success") else 409
    return jsonify(result), status


@app.route("/api/pause", methods=["POST"])
def api_pause():
    result = orchestrator.pause()
    status = 200 if result.get("success") else 409
    return jsonify(result), status


@app.route("/api/stop", methods=["POST"])
def api_stop():
    result = orchestrator.stop()
    status = 200 if result.get("success") else 409
    return jsonify(result), status


@app.route("/api/vm/<vm_name>/approve", methods=["POST"])
def api_approve(vm_name: str):
    result = orchestrator.approve_vm(vm_name)
    status = 200 if result.get("success") else 400
    return jsonify(result), status


@app.route("/api/vm/<vm_name>/retry", methods=["POST"])
def api_retry(vm_name: str):
    result = orchestrator.retry_vm(vm_name)
    status = 200 if result.get("success") else 400
    return jsonify(result), status


@app.route("/api/status", methods=["GET"])
def api_status():
    return jsonify(orchestrator.get_state())


@app.route("/api/report", methods=["GET"])
def api_report():
    return jsonify(orchestrator.get_report())


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False, threaded=True)
