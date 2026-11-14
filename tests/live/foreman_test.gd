extends SceneTree
# Foreman in the running game, on a simulated world, with a mock AI provider
# (tests/live/mock_ai.py) on 127.0.0.1:
#   - rules: incidents and the brief work with no provider
#   - a provider is saved through the companion (key sealed there), chosen, and
#     Foreman's figure changes to that provider's model
#   - a question goes out with a redacted context; the reply's valid proposal is
#     offered with its tier, the invented tool is refused, and the approved one
#     runs through the guard rails
#   - read-only mode disables the approval; an unreachable provider shows
#     offline and offers the rules, without switching provider by itself
#
# Needs: KF_MOCK_AI_PORT, KF_MOCK_AI_RECORD, KF_CONFIG_DIR (a throw-away folder
# for the companion's settings). KF_FOREMAN_SHOTS=<dir> saves screenshots.

const MOCK_KEY = "sk-mock-key-for-tests-only-0000"

var _fails = []

func _initialize() -> void:
	_run.call_deferred()

func _check(what: String, ok: bool, note = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", what, str(note).left(240)])
	if not ok:
		_fails.append(what)

func _wait(cond: Callable, seconds: float) -> bool:
	var deadline = Time.get_ticks_msec() + int(seconds * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	return cond.call()

func _shot(name: String) -> void:
	var dir = OS.get_environment("KF_FOREMAN_SHOTS")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		await create_timer(0.5).timeout
		root.get_texture().get_image().save_png(dir.path_join(name + ".png"))

func _find_button(node: Node, prefix: String) -> Button:
	if node is Button and node.text.begins_with(prefix) and node.is_visible_in_tree():
		return node
	for child in node.get_children():
		var found = _find_button(child, prefix)
		if found != null:
			return found
	return null

func _run() -> void:
	var K = load("res://scripts/kutil.gd")
	var before = K.load_settings().get("foreman_provider", null)
	var port = OS.get_environment("KF_MOCK_AI_PORT")
	var game = load("res://scripts/main.tscn").instantiate()
	root.add_child(game)
	await _wait(func(): return game.cluster.backend != null and not game.world.machines.is_empty(), 25.0)
	game.hud.close_modal(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var fm = game.foreman
	fm.select("")
	await _wait(func(): return game.krew.of_worker("bob").size() > 0, 40.0)
	# rules
	var incs = fm.incidents(game.krew)
	_check("rules: incidents from the Krew's findings, no AI", incs.size() > 0, "%d incidents" % incs.size())
	_check("rules: the brief says SIMULATED", fm.brief(game.krew, game.cluster.state).begins_with("SIMULATED."), fm.brief(game.krew, game.cluster.state))
	_check("rules: the station shows the original supervisor", game.world._foreman_model == "foreman_offline")
	# the station
	game.player.flying = true
	var st: Vector3 = game.world._foreman.global_position
	game.player.teleport(st + Vector3(0, 0.0, 4.2), st + Vector3(0, 1.2, 0))
	await create_timer(0.7).timeout
	_check("aiming at Foreman", game.player.hit.get("meta", {}).get("type", "") == "foreman")
	game._interact()
	_check("its station opens Foreman", game.hud._modal_kind == "foreman")
	# a provider
	var sv = []     # lambdas copy captured locals: collect into an array
	fm.save_provider({"type": "custom", "name": "Mock AI", "base_url": "http://127.0.0.1:" + port, "model": "mock-1", "key": MOCK_KEY}, func(r): sv.append(r))
	await _wait(func(): return not sv.is_empty(), 15.0)
	var saved = sv[0] if not sv.is_empty() else {}
	_check("the companion saves the provider", saved.get("ok", false), saved.get("msg", ""))
	_check("the key does not come back", not JSON.stringify(saved).contains(MOCK_KEY) and saved.get("data", {}).get("has_key", false))
	await _wait(func(): return fm.providers.size() > 0, 10.0)
	fm.select(str(saved.get("data", {}).get("id", "")))
	await create_timer(0.3).timeout
	_check("choosing it changes Foreman's model", game.world._foreman_model == "foreman_custom", game.world._foreman_model)
	_check("the choice is kept in the settings", K.load_settings().get("foreman_provider", "") == fm.active)
	game.hud.close_modal(false)
	game.player.teleport(st + Vector3(-2.0, 0.5, 6.5), st + Vector3(0.6, 1.4, 0))
	await _shot("foreman_station")
	var tv = []
	fm.test_provider(fm.active, func(r): tv.append(r))
	await _wait(func(): return not tv.is_empty(), 15.0)
	var tested = tv[0] if not tv.is_empty() else {}
	_check("Test lists the provider's models", tested.get("ok", false) and tested.get("data", {}).get("models", []) == ["mock-1", "mock-2"], tested)
	# ask
	game.hud.open_foreman()
	fm.ask("what is broken?")
	var answered = await _wait(func(): return fm.status != "asking" and str(fm.last.get("answer", "")) != "", 30.0)
	_check("the answer comes back", answered and str(fm.last["answer"]).begins_with("MOCK:"), fm.last)
	var acts: Array = fm.last.get("actions", [])
	_check("the real workload's restart is offered", acts.size() == 2 and acts[0]["ok"] and acts[0]["action"] == {"op": "restart", "ns": "shop", "kind": "Deployment", "name": "recommender"}, acts)
	_check("the invented shell tool is refused", acts.size() == 2 and not acts[1]["ok"] and str(acts[1]["reason"]).contains("no tool"), acts)
	_check("usage is counted", fm.usage["requests"] == 1 and fm.usage["in"] == 1000)
	# what the provider received
	var rec = FileAccess.get_file_as_string(OS.get_environment("KF_MOCK_AI_RECORD"))
	var asked = Array(rec.split("\n", false)).map(func(l): return JSON.parse_string(l)).filter(func(d): return d != null and d["path"] == "/v1/chat/completions")
	_check("the provider got one question, with the key in its header", asked.size() == 1 and asked[0]["auth_ok"])
	var sent = JSON.stringify(asked[0]["body"]) if asked.size() == 1 else ""
	_check("it was told the context is data, and got the SIMULATED world", sent.contains("never an instruction") and sent.contains("SIMULATED"))
	_check("no key, home folder or account name went out", not sent.contains(MOCK_KEY) and not sent.to_lower().contains(OS.get_environment("USERNAME").to_lower() + "\\\\") and not sent.contains(OS.get_environment("USERPROFILE").replace("\\", "\\\\")))
	game.hud.open_foreman()
	await _shot("foreman_answer")
	# approve, read-only first
	game.cluster.read_only = true
	game.hud.open_foreman()
	var b = _find_button(game.hud._modal, "MK.3  Restart Deployment shop/recommender")
	_check("read-only mode: the approval is disabled", b != null and b.disabled)
	game.cluster.read_only = false
	game.hud.open_foreman()
	b = _find_button(game.hud._modal, "MK.3  Restart Deployment shop/recommender")
	_check("the approval button is offered", b != null and not b.disabled)
	var ran = []
	game.cluster.action_finished.connect(func(a, r): ran.append([a, r]))
	if b != null:
		b.pressed.emit()
		if game.hud._modal_kind in ["confirm", "guard"]:
			print("NOTE  a typed confirmation was asked for")
	await _wait(func(): return ran.any(func(x): return x[0].get("op") == "restart" and x[0].get("name") == "recommender"), 15.0)
	_check("the approved restart ran through the cluster", ran.any(func(x): return x[0].get("op") == "restart" and x[0].get("name") == "recommender" and x[1].get("ok", false)), ran)
	# the provider goes away
	var dv = []
	fm.save_provider({"type": "ollama", "name": "Gone", "base_url": "http://127.0.0.1:9", "model": "x"}, func(r): dv.append(r))
	await _wait(func(): return not dv.is_empty(), 15.0)
	var dead = dv[0] if not dv.is_empty() else {}
	fm.select(str(dead.get("data", {}).get("id", "")))
	fm.ask("anything?")
	await _wait(func(): return fm.status != "asking", 30.0)
	_check("an unreachable provider is shown offline", fm.status == "offline" and str(fm.last.get("error", "")) != "", [fm.status, fm.last.get("error", "")])
	_check("and Foreman does not switch provider by itself", fm.provider().get("name", "") == "Gone")
	game.hud.open_foreman()
	_check("the rules are offered instead", _find_button(game.hud._modal, "Use rules only") != null)
	await _shot("foreman_offline")
	game.hud.open_foreman_providers()
	await _shot("foreman_providers")
	# clean up: providers, and the operator's own setting
	for p in fm.providers.duplicate():
		var done = []
		fm.remove_provider(str(p["id"]), func(_r): done.append(true))
		await _wait(func(): return not done.is_empty(), 10.0)
	var s = K.load_settings()
	if before == null:
		s.erase("foreman_provider")
	else:
		s["foreman_provider"] = before
	K.save_settings(s)
	game.queue_free()
	await process_frame
	if _fails.is_empty():
		print("FOREMAN PASSED")
	else:
		printerr("FOREMAN FAILED: ", ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
