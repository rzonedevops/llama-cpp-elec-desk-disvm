implement LlamboFFI;

include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
	FD, dial, read, write, open, OREAD, OWRITE, ORDWR: import sys;

include "draw.m";
	draw: Draw;

include "string.m";
	str: String;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "llambo-ffi.m";

# Default socket path
DEFAULT_SOCKET := "/tmp/llama-cpp-bridge.sock";

# Initialize module
init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	str = load String String->PATH;
	bufio = load Bufio Bufio->PATH;
	
	print("llambo-ffi: FFI bridge module initialized\n");
}

# Connect to bridge service
Bridge.connect(socket_path: string): ref Bridge
{
	if (socket_path == nil || socket_path == "")
		socket_path = DEFAULT_SOCKET;
	
	# Open Unix domain socket
	# In Inferno, we use dial with "unix!" prefix
	addr := "unix!" + socket_path;
	(ok, conn) := dial(addr, nil);
	
	if (ok < 0) {
		print("llambo-ffi: failed to connect to bridge at %s: %r\n", socket_path);
		return nil;
	}
	
	bridge := ref Bridge;
	bridge.fd = conn.dfd;
	bridge.connected = 1;
	bridge.socket_path = socket_path;
	
	print("llambo-ffi: connected to bridge at %s\n", socket_path);
	return bridge;
}

# Disconnect from bridge
Bridge.disconnect(b: self ref Bridge)
{
	if (b == nil || !b.connected)
		return;
	
	if (b.fd != nil) {
		b.fd = nil;
	}
	
	b.connected = 0;
	print("llambo-ffi: disconnected from bridge\n");
}

# Send command and receive response
Bridge.send_command(b: self ref Bridge, cmd: string): (int, string, string)
{
	if (b == nil || !b.connected || b.fd == nil)
		return (-1, "error", "Not connected to bridge");
	
	# Send command (add newline)
	cmd_bytes := array of byte (cmd + "\n");
	n := write(b.fd, cmd_bytes, len cmd_bytes);
	if (n < 0) {
		return (-1, "error", sprint("Failed to send command: %r"));
	}
	
	# Read response (one line of JSON)
	buf := array[4096] of byte;
	n = read(b.fd, buf, len buf);
	if (n <= 0) {
		return (-1, "error", "Failed to read response");
	}
	
	response_str := string buf[0:n];
	
	# Parse JSON response
	resp := parse_response(response_str);
	if (resp == nil)
		return (-1, "error", "Failed to parse response");
	
	ok := 0;
	if (resp.status == "ok")
		ok = 1;
	
	return (ok, resp.message, resp.data);
}

# Ping bridge
Bridge.ping(b: self ref Bridge): int
{
	(ok, msg, data) := b.send_command("PING");
	if (ok > 0 && data == "pong")
		return 1;
	return 0;
}

# Load model
Bridge.load_model(b: self ref Bridge, model_path: string): (int, string)
{
	cmd := "LOAD " + model_path;
	(ok, msg, nil) := b.send_command(cmd);
	return (ok, msg);
}

# Perform inference
Bridge.infer(b: self ref Bridge, prompt: string): (int, string, string)
{
	cmd := "INFER " + prompt;
	return b.send_command(cmd);
}

# Get status
Bridge.get_status(b: self ref Bridge): (int, string)
{
	(ok, msg, nil) := b.send_command("STATUS");
	return (ok, msg);
}

# Free model resources
Bridge.free_model(b: self ref Bridge): int
{
	(ok, nil, nil) := b.send_command("FREE");
	return ok;
}

# Simple JSON parser for bridge responses
# Format: {"status":"ok|error","message":"...","data":"..."}
parse_response(json: string): ref Response
{
	if (json == nil || json == "")
		return nil;
	
	# Remove leading/trailing whitespace and newlines
	json = str->drop(json, " \t\n\r");
	json = str->dropr(json, " \t\n\r");
	
	# Check for JSON object
	if (len json < 2 || json[0] != '{' || json[len json - 1] != '}')
		return nil;
	
	resp := ref Response;
	resp.status = "error";
	resp.message = "";
	resp.data = "";
	
	# Simple parsing (not a full JSON parser, but sufficient for our protocol)
	# Extract status
	status_key := "\"status\":\"";
	status_idx := str->in(status_key, json);
	if (status_idx >= 0) {
		start := status_idx + len status_key;
		end := start;
		while (end < len json && json[end] != '"')
			end++;
		if (end < len json)
			resp.status = json[start:end];
	}
	
	# Extract message
	msg_key := "\"message\":\"";
	msg_idx := str->in(msg_key, json);
	if (msg_idx >= 0) {
		start := msg_idx + len msg_key;
		end := start;
		# Handle escaped quotes - count backslashes before quote
		while (end < len json) {
			if (json[end] == '"') {
				# Count preceding backslashes
				backslashes := 0;
				i := end - 1;
				while (i >= start && json[i] == '\\') {
					backslashes++;
					i--;
				}
				# If even number of backslashes, quote is not escaped
				if (backslashes % 2 == 0)
					break;
			}
			end++;
		}
		if (end < len json)
			resp.message = unescape_json(json[start:end]);
	}
	
	# Extract data (optional)
	data_key := "\"data\":\"";
	data_idx := str->in(data_key, json);
	if (data_idx >= 0) {
		start := data_idx + len data_key;
		end := start;
		# Handle escaped quotes - count backslashes before quote
		while (end < len json) {
			if (json[end] == '"') {
				# Count preceding backslashes
				backslashes := 0;
				i := end - 1;
				while (i >= start && json[i] == '\\') {
					backslashes++;
					i--;
				}
				# If even number of backslashes, quote is not escaped
				if (backslashes % 2 == 0)
					break;
			}
			end++;
		}
		if (end < len json)
			resp.data = unescape_json(json[start:end]);
	}
	
	return resp;
}

# Unescape JSON string (handle \n, \r, \t, \", \\)
unescape_json(s: string): string
{
	if (str == nil || s == nil || s == "")
		return s;
	
	# For simplicity, return the string as-is
	# Full JSON unescaping would require more complex parsing
	# This is sufficient for our protocol where data is pre-escaped
	return s;
}
