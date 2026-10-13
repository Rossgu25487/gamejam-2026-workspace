extends RefCounted
## 材料唯一集合。视图和出示槽只保存引用，不复制或消耗实体。

var catalog: RefCounted
var entities: Dictionary = {}
var acquire_index := 0

func acquire(content_id: String, path: Dictionary, frozen: Array = []) -> bool:
	if not catalog.data.contents.has(content_id): return false
	var content: Dictionary = catalog.data.contents[content_id]
	var id: String = content.material_id
	if not entities.has(id):
		acquire_index += 1
		entities[id] = {"material_id": id, "type": catalog.data.materials[id].type, "acquire_index": acquire_index, "current_content_id": content_id, "acquired_content_ids": [], "viewed_content_ids": [], "important": false, "sources_by_content": {}}
	var entity: Dictionary = entities[id]
	if content_id not in entity.acquired_content_ids: entity.acquired_content_ids.append(content_id)
	if int(content.version) > int(catalog.data.contents[entity.current_content_id].version): entity.current_content_id = content_id
	if not entity.sources_by_content.has(content_id): entity.sources_by_content[content_id] = []
	var paths: Array = entity.sources_by_content[content_id]
	# 推论来源只能在首次形成时提交；普通材料按真实路径身份追加。
	if entity.type == "inference":
		if paths.is_empty(): entity.sources_by_content[content_id] = frozen.duplicate(true)
	else:
		var key := JSON.stringify([path.get("source_id", ""), path.get("entry_id", ""), path.get("relation_id", "")])
		for previous in paths:
			if previous.get("path_key", "") == key: return true
		var source := path.duplicate(true)
		source["path_key"] = key
		source["kind"] = "acquisition"
		paths.append(source)
	return true

func owns(ref: Dictionary) -> bool:
	return catalog.valid_material_ref(ref) and entities.has(ref.material_id) and ref.content_id in entities[ref.material_id].acquired_content_ids

func sources(ref: Dictionary) -> Array:
	if not owns(ref): return []
	return entities[ref.material_id].sources_by_content.get(ref.content_id, []).duplicate(true)

func freeze(ref: Dictionary) -> Dictionary:
	return {"kind": "material", "ref": ref.duplicate(true), "sources": sources(ref)} if owns(ref) else {}

func mark_read(ref: Dictionary) -> void:
	if owns(ref) and ref.content_id not in entities[ref.material_id].viewed_content_ids:
		entities[ref.material_id].viewed_content_ids.append(ref.content_id)

func marker(id: String) -> String:
	var entity: Dictionary = entities[id]
	if entity.current_content_id in entity.viewed_content_ids: return ""
	return "新" if entity.viewed_content_ids.is_empty() else "更新"

func list_refs(view: Dictionary) -> Array:
	var sorted: Array = entities.values()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary):
		var sort_key: String = view.get("sort", "acquire")
		if sort_key == "type" and a.type != b.type:
			return ["evidence", "testimony", "inference"].find(a.type) < ["evidence", "testimony", "inference"].find(b.type)
		if sort_key == "name":
			var a_name: String = catalog.text(catalog.data.contents[a.current_content_id].title)
			var b_name: String = catalog.text(catalog.data.contents[b.current_content_id].title)
			if a_name != b_name: return a_name < b_name
		return int(a.acquire_index) < int(b.acquire_index))
	var refs: Array = []
	for entity in sorted:
		if view.get("type", "all") != "all" and entity.type != view.type: continue
		if view.get("important_only", false) and not entity.important: continue
		refs.append(catalog.material_ref(entity.current_content_id))
	return refs

func validate(snapshot: Dictionary) -> bool:
	if not snapshot.get("entities") is Dictionary or not snapshot.has("acquire_index"): return false
	var indices: Array = []
	for id in snapshot.entities:
		var e = snapshot.entities[id]
		if not e is Dictionary or not catalog.data.materials.has(id): return false
		for key in ["material_id", "type", "acquire_index", "current_content_id", "acquired_content_ids", "viewed_content_ids", "important", "sources_by_content"]:
			if not e.has(key): return false
		if not e.acquired_content_ids is Array or not e.viewed_content_ids is Array or not e.sources_by_content is Dictionary: return false
		if e.material_id != id or e.type != catalog.data.materials[id].type: return false
		if int(e.acquire_index) < 1 or int(e.acquire_index) in indices: return false
		indices.append(int(e.acquire_index))
		if e.current_content_id not in e.acquired_content_ids: return false
		for content_id in e.acquired_content_ids:
			if not catalog.valid_material_ref({"material_id": id, "content_id": content_id}): return false
			if not e.sources_by_content.get(content_id) is Array: return false
			if int(catalog.data.contents[content_id].version) > int(catalog.data.contents[e.current_content_id].version): return false
		for content_id in e.viewed_content_ids:
			if content_id not in e.acquired_content_ids: return false
	return indices.is_empty() or int(snapshot.acquire_index) >= int(indices.max())

func export_state() -> Dictionary:
	return {"entities": entities.duplicate(true), "acquire_index": acquire_index}

func restore(snapshot: Dictionary) -> void:
	entities = snapshot.entities.duplicate(true)
	acquire_index = int(snapshot.acquire_index)
