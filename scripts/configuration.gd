extends RefCounted

const K = preload("res://scripts/kutil.gd")
const Apps = preload("res://scripts/apps.gd")
const BuildPlan = preload("res://scripts/build_plan.gd")

static func yaml(value, indent: int = 0) -> String:
	var pad = " ".repeat(indent)
	var lines = []
	if value is Dictionary:
		for key in value:
			var child = value[key]
			var complex = (child is Dictionary or child is Array) and not child.is_empty()
			lines.append(pad + JSON.stringify(str(key)) + ":" + ("\n" + yaml(child, indent + 2) if complex else " " + JSON.stringify(child)))
	elif value is Array:
		for child in value:
			var complex = (child is Dictionary or child is Array) and not child.is_empty()
			lines.append(pad + "-" + ("\n" + yaml(child, indent + 2) if complex else " " + JSON.stringify(child)))
	else:
		return pad + JSON.stringify(value)
	return "\n".join(lines)

static func documents(objects: Array, note: String = "") -> String:
	return ("# " + note.replace("\n", "\n# ") + "\n" if note != "" else "") + "\n---\n".join(objects.map(func(item): return yaml(item))) + "\n"

static func clean(objects: Array, namespace_filter: String = "") -> Array:
	var result = []
	for source in objects:
		if not source is Dictionary or source.get("kind") in ["Node", "Secret"]:
			continue
		var item: Dictionary = source.duplicate(true)
		var metadata: Dictionary = item.get("metadata", {})
		if namespace_filter != "" and metadata.get("namespace", "") != namespace_filter:
			continue
		if item.get("kind") == "Pod" and not metadata.get("ownerReferences", []).is_empty():
			continue
		item.erase("status")
		for key in ["uid", "resourceVersion", "generation", "creationTimestamp", "managedFields", "deletionTimestamp", "deletionGracePeriodSeconds", "ownerReferences"]:
			metadata.erase(key)
		metadata.get("annotations", {}).erase("kubectl.kubernetes.io/last-applied-configuration")
		if item.get("kind") == "Service":
			for key in ["clusterIP", "clusterIPs", "healthCheckNodePort"]:
				if item.get("spec", {}).get(key) != "None":
					item.get("spec", {}).erase(key)
		result.append(item)
	return result

static func _resource(kind: String, name: String, ns: String, spec: Dictionary) -> Dictionary:
	return {"apiVersion": "apps/v1" if kind in ["Deployment", "StatefulSet", "DaemonSet"] else ("batch/v1" if kind == "Job" else "v1"),
		"kind": kind, "metadata": {"name": name, "namespace": ns}, "spec": spec}

static func draft(state: Dictionary) -> String:
	var objects = []
	var groups = {}
	var namespaces = {}
	var claims = {}
	var docker = state.has("lab") or state.get("source") == "docker"
	for pod in state.get("pods", []):
		var via: String = pod.get("net", {}).get("via", "")
		var gateway = K.find_pod(state, via) if via != "" else null
		var owner: Dictionary = gateway if gateway != null else pod
		var ns = "kubefactory-media" if docker else str(owner.get("ns", "default"))
		if ns == "":
			ns = "default"
		var name = Apps.slug(str(owner.get("wname", "")) if owner.get("wname", "") != "" else str(owner["name"]))
		var key = ns + "/" + name
		if not groups.has(key):
			groups[key] = {"ns": ns, "name": name, "owner": owner, "members": []}
		groups[key]["members"].append(pod)
	for group in groups.values():
		var ns: String = group["ns"]
		var name: String = group["name"]
		namespaces[ns] = true
		var owner: Dictionary = group["owner"]
		var containers = {}
		var volumes = {}
		var services = {}
		var spec = {"containers": [], "volumes": []}
		var init = []
		var seen_containers = {}
		var unresolved = false
		for pod in group["members"]:
			var ports = []
			for binding in pod.get("docker_ports", []):
				var parsed = Apps.parse_port(binding["target"])
				if parsed[1] > 0:
					ports.append({"name": "p%d-%s" % [parsed[1], parsed[2].to_lower()], "port": parsed[1], "targetPort": parsed[1], "protocol": parsed[2]})
			if ports.is_empty():
				for service in state.get("services", []):
					if service["ns"] == pod["ns"] and not service.get("selector", {}).is_empty() and K.selects(service["selector"], pod.get("labels", {})):
						for port in str(service["ports"]).split(",", false):
							var parsed = Apps.parse_port(port.strip_edges())
							if parsed[1] > 0:
								ports.append({"name": "p%d-%s" % [parsed[1], parsed[2].to_lower()], "port": parsed[1], "targetPort": parsed[1], "protocol": parsed[2]})
			var unique_ports = {}
			for port in ports:
				unique_ports[port["name"]] = port
			ports = unique_ports.values()
			if not ports.is_empty():
				services[Apps.slug(str(pod.get("wname", pod["name"])))] = ports
			for source in pod.get("containers", []):
				var cn = Apps.slug(str(source["name"]))
				if seen_containers.has(cn):
					continue
				seen_containers[cn] = true
				var container = {"name": cn, "image": source["image"]}
				if str(source["image"]).contains("kubefactory/demo-"):
					unresolved = true
				var mounts = []
				for mount in pod.get("store", {}).get("shared_mounts", []):
					if mount.get("container", source["name"]) != source["name"]:
						continue
					var claim = Apps.slug(str(mount["name"]))
					claims[ns + "/" + claim] = _resource("PersistentVolumeClaim", claim, ns, {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "%dGi" % maxi(1, ceili(float(mount.get("capacity", 1073741824)) / 1073741824.0))}}})
					volumes[claim] = {"name": claim, "persistentVolumeClaim": {"claimName": claim}}
					mounts.append({"name": claim, "mountPath": mount["path"], "readOnly": mount.get("read_only", false)})
				if str(source["image"]).contains("qmcgaw/gluetun"):
					container["restartPolicy"] = "Always"
					container["securityContext"] = {"capabilities": {"add": ["NET_ADMIN"]}}
					container["envFrom"] = [{"secretRef": {"name": name + "-vpn"}}]
					container["startupProbe"] = {"exec": {"command": ["/gluetun-entrypoint", "healthcheck"]}, "periodSeconds": 5, "failureThreshold": 60}
					container["livenessProbe"] = {"exec": {"command": ["/gluetun-entrypoint", "healthcheck"]}, "periodSeconds": 10}
					volumes["tun-device"] = {"name": "tun-device", "hostPath": {"path": "/dev/net/tun", "type": "CharDevice"}}
					mounts.append({"name": "tun-device", "mountPath": "/dev/net/tun"})
					container["volumeMounts"] = mounts
					init.append(container)
				else:
					if not mounts.is_empty():
						container["volumeMounts"] = mounts
					containers[cn] = container
		var kind: String = owner.get("wkind", "Deployment")
		if kind not in ["Deployment", "StatefulSet", "DaemonSet", "Job"]:
			kind = "Deployment"
		if containers.is_empty():
			# A gateway-only source still needs a regular container in a valid Pod.
			var gateway = init.pop_back() if not init.is_empty() else {"name": "configure-me", "image": "REPLACE_IMAGE"}
			gateway.erase("restartPolicy")
			containers[gateway["name"]] = gateway
			unresolved = true
		spec["containers"] = containers.values()
		spec["volumes"] = volumes.values()
		if not init.is_empty():
			spec["initContainers"] = init
		elif group["members"].any(func(pod): return pod.get("net", {}).get("via", "") != ""):
			unresolved = true
		if kind == "Job":
			spec["restartPolicy"] = "Never"
		var workload = {"selector": {"matchLabels": {"app": name}}, "template": {"metadata": {"labels": {"app": name}}, "spec": spec}}
		if kind == "Job":
			workload.erase("selector")
		elif kind != "DaemonSet":
			var current = K.find_workload(state, owner["ns"], owner["wkind"], owner["wname"])
			workload["replicas"] = 0 if unresolved else int(current.get("replicas", 1) if current != null else 1)
		if kind == "StatefulSet":
			workload["serviceName"] = name
		var resource = _resource(kind, name, ns, workload)
		if unresolved:
			resource["metadata"]["annotations"] = {"kubefactory.io/review-required": "Replace simulated images or configure the shared VPN before starting."}
		objects.append(resource)
		for service in services:
			var service_spec = {"selector": {"app": name}, "ports": services[service], "type": "ClusterIP"}
			if kind == "StatefulSet" and service == name:
				service_spec["clusterIP"] = "None"
			objects.append(_resource("Service", service, ns, service_spec))
	var preamble = []
	for ns in namespaces:
		preamble.append({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}})
	preamble.append_array(claims.values())
	preamble.append_array(objects)
	if not state.get("links", []).is_empty():
		preamble.append({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "kubefactory-topology", "namespace": namespaces.keys()[0]},
			"data": {"connections.json": JSON.stringify(state["links"], "  ")}})
	return documents(preamble, "Kubernetes / k3s map draft. Review before deployment.\nEnvironment settings, application config, routing/VLAN policy and storage drivers need operator review.\nServices stay private (ClusterIP). Shared PVCs require compatible storage and placement.\nGluetun groups use native sidecars (Kubernetes/k3s 1.29+), need a <gateway>-vpn Secret, and wait for VPN health.\nSimulated images and unsupported VPN groups remain stopped. Existing YAML files can be opened without conversion.")

static func flowchart_yaml(plan: Dictionary) -> String:
	plan = BuildPlan.migrate(plan)
	if BuildPlan.problem(plan) != "":
		return "# Invalid plan: " + BuildPlan.problem(plan) + "\n"
	var state = {"source": "simulation", "pods": [], "services": [], "workloads": [], "links": []}
	var used_names = {}
	for i in plan.get("nodes", []).size():
		var node = plan["nodes"][i]
		if node.get("resource_type", "workload") != "workload":
			continue
		var parts = str(node["title"]).split("/", false)
		if parts.is_empty():
			parts.append("workload-%d" % i)
		var ns = Apps.slug(parts[0]) if parts.size() > 1 else "planned"
		var name = Apps.slug(parts[-1])
		if name == "":
			name = "workload-%d" % i
		if used_names.has(ns + "/" + name):
			name += "-%d" % i
		used_names[ns + "/" + name] = true
		state["pods"].append({"uid": node["id"], "name": name, "ns": ns, "wkind": "Deployment", "wname": name,
			"containers": [{"name": name, "image": node.get("image", "") if node.get("image", "") != "" else "kubefactory/demo-replace-image"}], "store": {"shared_mounts":[]}, "net": {}, "labels": {}, "docker_ports":node.get("bindings",[])})
		state["workloads"].append({"ns":ns,"kind":"Deployment","name":name,"replicas":0})
	for edge in plan.get("edges", []):
		state["links"].append(edge.duplicate(true))
		var a = K.find_pod(state,edge["from"])
		var b = K.find_pod(state,edge["to"])
		if edge["kind"] == "VPN" and a != null and b != null:
			a["net"]["via"] = b["uid"]
		if edge["kind"] in ["Mounts","Files"] and (a != null) != (b != null):
			var app: Dictionary = a if a != null else b
			var volume = plan["nodes"].filter(func(n): return n["id"] == (edge["to"] if a != null else edge["from"]))[0]
			if volume.get("resource_type") == "volume":
				app["store"]["shared_mounts"].append({"name":Apps.slug(volume["title"]),"container":app["containers"][0]["name"],
					"path":edge.get("mount_path","") if edge.get("mount_path","") != "" else "/data/"+Apps.slug(volume["title"]),"read_only":edge.get("read_only",false)})
	var ns: String = state["pods"][0]["ns"] if not state["pods"].is_empty() else "planned"
	var objects = [{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "kubefactory-flowchart", "namespace": ns}, "data": {"flowchart.json": JSON.stringify(plan, "  ")}}]
	if state["pods"].is_empty():
		objects.push_front({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}})
	return draft(state) + "---\n" + documents(objects)

static func compose_plan(plan: Dictionary) -> Dictionary:
	if BuildPlan.problem(plan) != "":
		return {}
	var result = {"name":"kubefactory-plan", "services":{}, "volumes":{}, "networks":{},
		"x-kubefactory":{"review":"Local draft. Review images, credentials, app settings, storage and network policy before compose up. VLAN labels are intent, not enforcement. Shared VPN clients share their gateway network namespace.","plan":plan.duplicate(true)}}
	var names = {}
	var nodes = {}
	var gateways = {}
	for node in plan["nodes"]:
		nodes[node["id"]] = node
		var title = Apps.slug(node["title"])
		var name = (title if title != "" else "block")+"-"+node["id"].to_lower()
		names[node["id"]] = name
		if node.get("resource_type", "workload") == "volume":
			result["volumes"][name] = {}
		elif node.get("resource_type", "workload") == "workload":
			var image: String = node.get("image", "")
			var service = {"image":image if image != "" else "REPLACE_IMAGE", "networks":{}, "labels":{"kubefactory.io/block-id":node["id"],"kubefactory.io/vlan-intent":str(node["vlan"])}}
			if image == "" or image.contains("kubefactory/demo-"):
				service["profiles"] = ["review-required"]
			var ports = []
			var expose = []
			for binding in node.get("bindings", []):
				var parsed = Apps.parse_port(binding.get("target",""))
				if parsed[1] <= 0:
					continue
				if str(binding.get("published","")).is_valid_int():
					ports.append({"target":parsed[1],"published":str(binding["published"]),"host_ip":binding.get("ip","127.0.0.1"),"protocol":str(parsed[2]).to_lower()})
				else:
					expose.append(binding["target"])
			if not ports.is_empty():
				service["ports"] = ports
			if not expose.is_empty():
				service["expose"] = expose
			if image.contains("qmcgaw/gluetun"):
				service["cap_add"] = ["NET_ADMIN"]
				service["devices"] = ["/dev/net/tun:/dev/net/tun"]
				service["environment"] = {"VPN_SERVICE_PROVIDER":"REPLACE_PROVIDER","VPN_TYPE":"wireguard","WIREGUARD_PRIVATE_KEY":"REPLACE_PRIVATE_KEY","WIREGUARD_ADDRESSES":"REPLACE_ADDRESS"}
				service["healthcheck"] = {"test":["CMD","/gluetun-entrypoint","healthcheck"],"interval":"10s","timeout":"5s","retries":6}
				service["profiles"] = ["review-required"]
			result["services"][name] = service
	for edge in plan["edges"]:
		if edge["kind"] == "VPN" and result["services"].has(names[edge["from"]]) and result["services"].has(names[edge["to"]]):
			gateways[edge["from"]] = edge["to"]
	for index in plan["edges"].size():
		var edge = plan["edges"][index]
		var a = edge["from"]
		var b = edge["to"]
		var volume = a if nodes[a].get("resource_type") == "volume" else (b if nodes[b].get("resource_type") == "volume" else "")
		if volume != "" and edge["kind"] in ["Mounts","Files"]:
			var app = b if volume == a else a
			if result["services"].has(names[app]):
				var service: Dictionary = result["services"][names[app]]
				if not service.has("volumes"):
					service["volumes"] = []
				var mount = {"type":"volume","source":names[volume],"target":edge.get("mount_path","") if edge.get("mount_path","") != "" else "/data/"+Apps.slug(nodes[volume]["title"]),"read_only":edge.get("read_only",false)}
				if mount not in service["volumes"]:
					service["volumes"].append(mount)
			continue
		if edge["kind"] == "Mounts" or (edge["kind"] == "VPN" and gateways.get(a) == b) or volume != "":
			continue
		var network = "route-%d" % (index+1)
		result["networks"][network] = {"internal":nodes[a].get("resource_type") != "boundary" and nodes[b].get("resource_type") != "boundary"}
		for id in [a,b]:
			var owner: String = gateways.get(id,id)
			if result["services"].has(names[owner]):
				var networks: Dictionary = result["services"][names[owner]]["networks"]
				if not networks.has(network):
					networks[network] = {"aliases":[]}
				if owner != id and names[id] not in networks[network]["aliases"]:
					networks[network]["aliases"].append(names[id])
	for app in gateways:
		var service: Dictionary = result["services"][names[app]]
		var gateway: String = names[gateways[app]]
		service.erase("networks")
		service["network_mode"] = "service:"+gateway
		service["depends_on"] = {gateway:{"condition":"service_healthy" if result["services"][gateway].has("healthcheck") else "service_started"}}
		if result["services"][gateway].has("profiles"):
			service["profiles"] = result["services"][gateway]["profiles"].duplicate()
		if service.has("ports"):
			if not result["services"][gateway].has("ports"):
				result["services"][gateway]["ports"] = []
			result["services"][gateway]["ports"].append_array(service["ports"])
			service.erase("ports")
	for name in result["services"]:
		var service: Dictionary = result["services"][name]
		if service.has("networks") and service["networks"].is_empty():
			result["networks"]["isolated-"+name] = {"internal":true}
			service["networks"] = {"isolated-"+name:{}}
	return result

static func porter_yaml(app: Dictionary, ns: String) -> String:
	var path = Apps.file_for(app["id"], "k8s")
	if not FileAccess.file_exists(path):
		return ""
	var text = FileAccess.get_file_as_string(path).replace("\r\n", "\n")
	# Bundled setup documents have a block-style, top-level metadata section.
	text = text.replace("\nmetadata:\n", "\nmetadata:\n  namespace: " + JSON.stringify(ns) + "\n")
	var objects = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}}]
	if app.get("secret", false):
		objects.append({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "app-db", "namespace": ns}, "type": "Opaque", "stringData": {"password": "REPLACE_BEFORE_DEPLOYMENT"}})
	return documents(objects, "Porter proposal for " + ns + ". Kubernetes / k3s. Review credentials and storage before deployment.") + "---\n" + text

static func porter_board(state: Dictionary, app: Dictionary, ns: String, manifest: String = "") -> Dictionary:
	var board = state.duplicate(true)
	board["board"] = []
	board["links"] = state.get("links", []).duplicate(true)
	for pod in state["pods"]:
		board["board"].append([pod["uid"], pod["name"], "Existing | " + pod["node"], "existing"])
	var cluster_id = "target:" + state["context"]
	var target = state["nodes"][0]["name"] if state["nodes"].size() == 1 else state["context"]
	board["board"].append([cluster_id, "TARGET: " + target, "Namespace: " + ns + " | automatic scheduling", "target"])
	for id in state.get("lab", {}).get("fixtures", {}):
		if id != "sync-switch":
			board["board"].append(["lab:" + id, id, "Existing storage / boundary", "existing"])
	var node_ids = {}
	for node in state["nodes"]:
		var id = "node:" + node["name"]
		node_ids[node["name"]] = id
		board["board"].append([id, node["name"], "Existing node", "existing"])
		board["links"].append({"from": cluster_id, "to": id, "kind": "Placement", "ready": true, "what": "Current cluster node"})
	for pod in state["pods"]:
		board["links"].append({"from": node_ids.get(pod["node"], cluster_id), "to": pod["uid"], "kind": "Placement", "ready": true, "what": "Existing placement"})
	for row in app["sim"]:
		var id = "planned:" + ns + "/" + row[1]
		var updating = state.get("workloads", []).any(func(workload): return workload["ns"] == ns and workload["name"] == row[1])
		board["board"].append([id, "+ " + row[1], ("UPDATE " if updating else "NEW ") + row[0] + " | " + str(row[4]), "planned"])
		board["links"].append({"from": cluster_id, "to": id, "kind": "Placement", "ready": true, "what": "Proposed addition to " + ns})
		var service = id + "/service"
		board["board"].append([service, row[1] + " service", str(row[4]), "planned"])
		board["links"].append({"from": service, "to": id, "kind": "API", "ready": true, "what": "Configured Service selector"})
		if row.size() > 5:
			for sidecar in row[5]:
				var sidecar_id = id + "/" + sidecar[0]
				board["board"].append([sidecar_id, "+ " + sidecar[0], "Sidecar in " + row[1] + " Pod", "planned"])
				board["links"].append({"from": id, "to": sidecar_id, "kind": "VPN", "ready": true, "what": "Shared Pod network"})
	var text = manifest if manifest != "" else (FileAccess.get_file_as_string(Apps.file_for(app["id"], "k8s")) if app.has("id") else "")
	var kind_pattern = RegEx.new()
	var name_pattern = RegEx.new()
	kind_pattern.compile("(?m)^kind:[ \\t]*([A-Za-z]+)")
	name_pattern.compile("(?m)^  name:[ \\t]*([a-z0-9-]+)")
	var resource_ids = {}
	var docs = text.split("\n---", false)
	var document_names = {}
	for doc in docs:
		var kind_match = kind_pattern.search(doc)
		var name_match = name_pattern.search(doc)
		if kind_match == null or name_match == null or kind_match.get_string(1) not in ["PersistentVolumeClaim", "ConfigMap", "Secret"]:
			continue
		var name = name_match.get_string(1)
		var id = "planned:" + ns + "/resource/" + name
		resource_ids[name] = id
		document_names[name] = doc
		board["board"].append([id, "+ " + name, kind_match.get_string(1), "planned"])
	if app.get("secret", false):
		resource_ids["app-db"] = "planned:" + ns + "/resource/app-db"
		board["board"].append([resource_ids["app-db"], "+ app-db", "Secret | value supplied on deployment", "planned"])
	var configuration_users = {}
	for doc in docs:
		var kind_match = kind_pattern.search(doc)
		var name_match = name_pattern.search(doc)
		if kind_match == null or name_match == null or kind_match.get_string(1) not in ["Deployment", "StatefulSet", "DaemonSet"]:
			continue
		var from = "planned:" + ns + "/" + name_match.get_string(1)
		for name in resource_ids:
			var reference = RegEx.new()
			reference.compile("(?:claimName:|configMap:[ \\t]*\\{name:|secretKeyRef:[ \\t]*\\{name:)[ \\t]*" + name + "(?:[,} \\n]|$)")
			if reference.search(doc) != null:
				board["links"].append({"from": from, "to": resource_ids[name], "kind": "Mounts" if "claimName: " + name in doc else "Configuration", "ready": true, "what": "Setup resource reference"})
				if not configuration_users.has(name):
					configuration_users[name] = []
				configuration_users[name].append(from)
		for row in app["sim"]:
			if row[1] == name_match.get_string(1):
				continue
			if "value: " + row[1] + "}" in doc or "value: " + row[1] + ":" in doc:
				board["links"].append({"from": from, "to": "planned:" + ns + "/" + row[1], "kind": "API", "ready": true, "what": "Setup host setting"})
	for name in configuration_users:
		if not document_names.has(name):
			continue
		for row in app["sim"]:
			var host = RegEx.new()
			host.compile("(?:https?://|['\\\"\\[])[ \\t]*" + row[1] + ":[0-9]+")
			if host.search(document_names[name]) != null:
				for from in configuration_users[name]:
					board["links"].append({"from": from, "to": "planned:" + ns + "/" + row[1], "kind": "Metrics", "ready": true, "what": "Configured reporting endpoint"})
	return board
