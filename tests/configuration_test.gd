extends SceneTree

const Config = preload("res://scripts/configuration.gd")
const ConfigEditor = preload("res://scripts/configuration_editor.gd")
const Demo = preload("res://scripts/backend_demo.gd")
const Apps = preload("res://scripts/apps.gd")
const Board = preload("res://scripts/lab_connections.gd")
var failures = 0

func _check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var directory = ProjectSettings.globalize_path("res://tests/generated-config-qa")
	DirAccess.make_dir_recursive_absolute(directory)
	var state = Demo.new("docker-media-gatherer").fetch()
	var before = JSON.stringify(state)
	var draft = Config.draft(state)
	_check(ConfigEditor.write_file(directory.path_join("media-map.yaml"), draft) == OK, "map draft exports to a local YAML file")
	_check('"initContainers":' in draft and '"restartPolicy": "Always"' in draft and '"startupProbe":' in draft,
		"shared Docker VPN converts to a guarded sidecar Pod")
	var wordpress = Apps.find("wordpress")
	var manifest = Config.porter_yaml(wordpress, "review-site")
	ConfigEditor.write_file(directory.path_join("porter-wordpress.yaml"), manifest)
	var proposal = Config.porter_board(state, wordpress, "review-site", manifest)
	_check(JSON.stringify(state) == before, "Porter preview leaves the current cluster unchanged")
	_check(proposal["board"].any(func(card): return card[0] == "planned:review-site/resource/mysql-data"), "Porter includes the proposed persistent data container")
	_check(proposal["links"].any(func(edge): return edge["from"] == "planned:review-site/wordpress" and edge["to"] == "planned:review-site/mysql"), "Porter shows the configured WordPress database connection")
	var monitoring = Apps.find("monitoring")
	var monitoring_yaml = Config.porter_yaml(monitoring, "reporting-review")
	var monitoring_plan = Config.porter_board(state, monitoring, "reporting-review", monitoring_yaml)
	_check(monitoring_plan["links"].any(func(edge): return edge["from"] == "planned:reporting-review/grafana" and edge["to"] == "planned:reporting-review/prometheus"),
		"Porter shows Grafana's configured Prometheus data source")
	for app in Apps.APPS:
		var text = Config.porter_yaml(app, "review-" + app["id"])
		_check(text != "" and "namespace:" in text, app["name"] + " has a namespaced export")
		ConfigEditor.write_file(directory.path_join("porter-" + app["id"] + ".yaml"), text)
	var board = Board.new()
	root.add_child(board)
	board.size = Vector2(1200, 700)
	board.selected_uid = "target:" + state["context"]
	board.refresh(proposal)
	await process_frame
	_check(board.cards.size() == proposal["board"].size() and board.get_connection_list().size() == proposal["links"].size(), "Porter board keeps all existing and proposed endpoints and edges")
	board.queue_free()
	var raw = [{"apiVersion": "example.com/v1", "kind": "CustomWorkload", "metadata": {"name": "sample", "namespace": "ns", "uid": "runtime-id", "managedFields": []},
		"spec": {"custom": {"setting": "keep", "probe": {"path": "/ready"}}}, "status": {"ready": true}},
		{"apiVersion": "v1", "kind": "Service", "metadata": {"name": "sample", "namespace": "ns"}, "spec": {"clusterIP": "10.0.0.2", "ports": [{"port": 80}]}},
		{"kind": "Pod", "metadata": {"namespace": "ns", "ownerReferences": [{"kind": "Deployment"}]}}, {"kind": "Secret", "data": {"password": "not-exported"}}]
	var cleaned = Config.clean(raw, "ns")
	_check(cleaned.size() == 2 and cleaned[0]["spec"] == raw[0]["spec"] and not cleaned[0].has("status") and not cleaned[0]["metadata"].has("uid"),
		"live export preserves arbitrary specs and removes runtime metadata")
	_check(not cleaned[1]["spec"].has("clusterIP"), "live export removes assigned Service addresses")
	var panel = ConfigEditor.new()
	root.add_child(panel)
	panel.setup(manifest, "review.yaml", {}, Callable())
	var arbitrary = "# Keep comments and YAML anchors\napiVersion: sample.io/v1\nkind: CustomThing\nmetadata: {name: example}\nspec:\n  defaults: &settings {enabled: true}\n  selected: *settings\n---\nkind: ConfigMap\napiVersion: v1\nmetadata: {name: extras}\ndata: {message: 'hello: world'}\n"
	panel.load_yaml(arbitrary, "custom.yaml")
	panel.editor.ed.text += "# reviewed\n"
	panel.request_export()
	_check(panel.approval.visible and panel._snapshot == arbitrary + "# reviewed\n", "export waits for approval of the exact edited YAML snapshot")
	panel.approval.hide()
	var destination = directory.path_join("edited-custom.yaml")
	_check(ConfigEditor.write_file(destination, panel._snapshot) == OK and FileAccess.get_file_as_string(destination) == arbitrary + "# reviewed\n",
		"arbitrary multi-document YAML exports without losing comments, anchors or edits")
	panel.editor._saved_text = panel.editor.ed.text
	panel.queue_free()
	var flow = Config.flowchart_yaml({"nodes": [{"title": "", "vlan": 30}, {"title": "apps/web", "vlan": 20}], "edges": [[0, 1, 0]]})
	ConfigEditor.write_file(directory.path_join("flowchart.yaml"), flow)
	_check('"replicas": 0' in flow and "connections.json" in flow, "new flowchart workloads remain stopped until their images are configured")
	print("CONFIGURATION PASSED" if failures == 0 else "CONFIGURATION FAILED")
	quit(0 if failures == 0 else 1)
