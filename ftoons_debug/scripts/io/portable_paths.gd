extends RefCounted
## The debug project owns its imports and player files regardless of the caller's
## working directory. The editor opens the project folder selected by the user.

static func root_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").trim_suffix("/")
	return OS.get_executable_path().get_base_dir()

static func profile() -> String:
	return root_dir().path_join("player_data")

static func work() -> String:
	return root_dir().path_join(".import_work")

static func assets_folder(edition: String) -> String:
	return root_dir().path_join("assets" if edition == "dos" else "dlc_win_data")
