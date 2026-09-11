std = "luajit"
cache = true

globals = {
	"vim",
}

ignore = {
	"212",
	"213",
	"631",
}

files["tests/"] = {
	globals = {
		"describe",
		"it",
		"before_each",
		"after_each",
		"assert",
		"pending",
		"setup",
		"teardown",
	},
}
