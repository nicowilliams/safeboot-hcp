import re

# The "language" for filtering JSON objects is implemented in HcpJsonPolicy,
# and it leans heavily on the "path" concept implemented in this file. This
# concept and syntax imitates how the 'jq' tool addresses the same need, which
# is to translate the filesystem "path" concept so it describes how to drill
# into a hierarchical JSON object to identify a field within it.
#
# Eg. for this JSON;
#     { "USA": { "NY": { "NYC": "Heavy cloud but no rain" } } }
# piping it through 'jq -r ".USA.NY" gives;
#     { "NYC": "Heavy cloud but no rain" }
# and through 'jq -r ".USA.NY.NYC"' gives;
#     Heavy cloud but no rain
# So ".USA.NY" and ".USA.NY.NYC" represent "paths" into the structure. The path
# to the entire/original structure is "."

valid_path_char_re = '[A-Za-z0-9_<>-]'
valid_path_node_re = f'{valid_path_char_re}{valid_path_char_re}*'
valid_path_node_prog = re.compile(valid_path_node_re)

class HcpJsonPathError(Exception):
	pass

def valid_path_node(node):
	if not valid_path_node_prog.fullmatch(node):
		raise HcpJsonPathError(f"HCP JSON, invalid path node: '{node}'")

def path_pop_node(path):
	if len(path) < 1:
		return None, path
	if path[0:1] != ".":
		raise HcpJsonPathError(f"HCP JSON, path nodes must begin with '.': '{path}'")
	path = path[1:]
	index = path.find(".")
	if index == 0:
		raise HcpJsonPathError(f"HCP JSON, path nodes must be non-empty: '{path}'")
	if index < 0:
		node = path
		path = ""
	else:
		node = path[0:index]
		path = path[index:]
	valid_path_node(node)
	return node, path

def valid_path(path):
	if not isinstance(path, str):
		raise HcpJsonPathError("HCP JSON, path is not a string")
	if path == ".":
		return
	while True:
		node, path = path_pop_node(path)
		if len(path) == 0:
			return

# Given a JSON path ("." for top-level, ".path.to.desired.field" for
# lower-level elements), return the corresponding field from the input data.
# Note that only the final field can be anything other than a 'dict' object,
# all the intermediate nodes in the path must be 'dict' objects. This function
# returns a 2-tuple to convey success/failure, as it shouldn't throw
# exceptions. (Policy logic will process rules and extract and compare paths
# between different structures, e.g. when determining if two structures are
# "equal", and it is not "exceptional" for a path to be missing during
# processing - that is just a sign that the "equal" comparison should return
# False. So that's what we do, because try/except handling is a worse
# experience for the caller.
def extract_path(data, path):
	if path == '.':
		return True, data
	while True:
		if not isinstance(data, dict):
			return False, None
		node, path = path_pop_node(path)
		if node not in data:
			return False, None
		data = data[node]
		if len(path) == 0:
			return True, data

# Given a JSON path, set the corresponding field in the output data. Note,
# the return value replaces the 'data' parameter, in order to handle the case
# where path==".". (I.e. when you are replacing all the data.) Note that if
# the path consists of intermediate nodes (necessarily object/dict) that
# don't exist in 'data', they will be created on-the-fly. Similarly, if the
# path traverses fields in 'data' that exist and are not 'dict's, those
# fields get discarded and replaced with (empty) 'dict's as the path is
# processed. (In this way, this function has no failure condition.)
def overwrite_path(data, path, value):
	if path == '.':
		return value
	cursor = data
	while True:
		node, path = path_pop_node(path)
		if len(path) == 0:
			cursor[node] = value
			return data
		if node not in cursor or not isinstance(cursor[node], dict):
			cursor[node] = {}
		cursor = cursor[node]

# Fairly self-explanatory given the last two functions. Special case, if you
# try to delete ".", it will return an empty dict ("{}") rather than None.  The
# latter would logically consistent, but in practice it would be difficult to
# insulate run-time behaviour from bad inputs (in terms of cryptic run-time
# exceptions rather than the preferred alternative: the user getting data
# that's emptier than they were expecting). If the path doesn't exist in the
# data, we return success without modifying anything. If we hit a non-dict
# field before reaching the conclusion of the path, we consider that passive
# success too, though one could argue that this isn't the best approach...
def delete_path(data, path):
	if path == '.':
		return {}
	cursor = data
	while True:
		node, path = path_pop_node(path)
		if len(path) == 0:
			if node in cursor:
				cursor.pop(node)
			return data
		if node not in cursor or not isinstance(cursor[node], dict):
			return data
		cursor = cursor[node]
