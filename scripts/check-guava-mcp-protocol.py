#!/usr/bin/env python3
"""Exercise the real stdio executable without a running editor or model key."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
configured_server = os.environ.get('GUAVA_MCP_EXECUTABLE')
candidates = [ROOT / 'GuavaMcp/.build/out/Products/Debug/GuavaMCP', ROOT / 'GuavaMcp/.build/debug/GuavaMCP']
if configured_server:
    candidates = [Path(configured_server)]
server = next(path for path in candidates if path.is_file())
requests = [
    json.dumps({'jsonrpc': '2.0', 'id': 8, 'method': 'tools/call', 'params': {'name': 'compile_scripts', 'arguments': []}}),
    '',
    '{invalid json',
    json.dumps({'id': 1, 'method': 'ping'}),
    json.dumps({'jsonrpc': '2.0', 'id': 2, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26'}}),
    json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
    json.dumps({'jsonrpc': '2.0', 'id': 3, 'method': 'ping'}),
    json.dumps({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/list'}),
    json.dumps({'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call', 'params': {'name': 'write_script', 'arguments': {'filename': 'Game.swift', 'source': 'source'}}}),
    json.dumps({'jsonrpc': '2.0', 'id': 6, 'method': 'unknown'}),
    json.dumps({'jsonrpc': '2.0', 'id': 7, 'method': 'initialize', 'params': {'protocolVersion': 'future-version'}}),
    json.dumps({'jsonrpc': '2.0', 'id': 9, 'method': 'prompts/list'}),
    json.dumps({'jsonrpc': '2.0', 'id': 10, 'method': 'prompts/get', 'params': {'name': 'ui-diagnostics'}}),
]
result = subprocess.run([str(server)], input='\n'.join(requests) + '\n', capture_output=True,
                        text=True, timeout=10, env=dict(os.environ, GUAVA_MCP_PORT='1'))
assert result.returncode == 0, result.stderr
messages = [json.loads(line) for line in result.stdout.splitlines()]
assert len(messages) == 11, messages
by_id = {message['id']: message for message in messages}
assert by_id[None]['error']['code'] == -32700
assert by_id[1]['error']['code'] == -32600
assert by_id[8]['error']['code'] == -32602
assert by_id[2]['result']['protocolVersion'] == '2025-03-26'
assert by_id[3]['result'] == {}
tools = by_id[4]['result']['tools']
assert {'write_script', 'compile_scripts', 'get_runtime_state', 'export_project', 'search_capabilities', 'submit_plan', 'reload_plugin'} <= {tool['name'] for tool in tools}
assert 'respond' not in {tool['name'] for tool in tools}
assert {'get_diagnostics', 'query_ui_nodes', 'query_ui_recomposition', 'query_ui_state',
        'capture_ui_trace', 'get_ui_trace', 'compare_ui_traces', 'list_skills', 'read_skill'} <= {tool['name'] for tool in tools}
assert by_id[9]['result']['prompts'][0]['name'] == 'ui-diagnostics'
assert 'query_ui_nodes' in by_id[10]['result']['messages'][0]['content']['text']
write = next(tool for tool in tools if tool['name'] == 'write_script')
assert write['inputSchema']['additionalProperties'] is False
assert 'expected_sha256' not in write['inputSchema']['required']
assert by_id[5]['result']['isError'] is True  # Disconnection must not appear successful.
assert by_id[6]['error']['code'] == -32601
assert by_id[7]['result']['protocolVersion'] == '2025-11-25'
print('Guava MCP protocol passed: framing, malformed input, negotiation, ping, tools and real disconnect errors')
