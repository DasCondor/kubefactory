extends SceneTree
# Downloads every list in catalogs.json and reports how many templates pass validation.
#   engine\Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/lists_check.gd

func _init():
	var Apps = load("res://scripts/apps.gd")
	for cat in Apps.load_catalogs():
		var r = Apps.fetch_templates(cat)
		if not r.ok:
			print("FAILED  ", cat["name"], "  ", r.text.left(120))
			continue
		var d = JSON.parse_string(r.text)
		var refused = {}
		for t in d["templates"]:
			var p = Apps.template_problem(t)
			if p != "":
				refused[p] = refused.get(p, 0) + 1
		print("%-26s %4d container templates, refused: %s" % [cat["name"], d["templates"].size(), refused])
	quit()
