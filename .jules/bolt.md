## 2024-03-27 - [Avoid find_children for dynamic indicators]
**Learning:** Using `find_children("*", "Node", true, false)` on every tick or selection change to find previously instantiated networked indicators is O(N) where N is the total number of nodes in the scene. In a large project, this causes a major CPU spike when deselecting or receiving selection updates.
**Action:** Use Godot's built-in grouping system (`add_to_group("TeamCreateSelectionOutlines")` and `get_tree().get_nodes_in_group(...)`) for O(1) lookup of dynamic UI/networking indicators scattered throughout the scene tree.

## 2024-04-18 - [MD5 Hashing Cache]
**Learning:** Calling `FileAccess.get_md5(path)` on every file during network synchronization `_on_filesystem_changed` causes severe O(N) lag (where N is the total project files). Hashing large assets repeatedly blocks the main thread.
**Action:** Implement an MD5 cache storing the hash and the file's last modified time (`FileAccess.get_modified_time`). Always check the modified time before re-hashing to achieve O(1) lookups for unchanged files. Remember to clear cache entries when files are removed.
