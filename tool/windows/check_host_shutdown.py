"""Check the Release host exits after EOF with a real HTTP keep-alive socket.
Only a temporary synthetic database and a loopback HTTP server are used.
"""
import http.server
import json
import pathlib
import queue
import subprocess
import tempfile
import threading
import time

root = pathlib.Path(__file__).resolve().parents[2]
exe = root / 'build/windows-moteur/bundle/bin/shopikaiss_moteur.exe'
received = threading.Event()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except ConnectionResetError:
            pass  # Expected when the synthetic client closes its connection.

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        body = b'{"message":"Synthetic pairing refused"}'
        self.send_response(400)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'keep-alive')
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        received.set()

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
folder = tempfile.mkdtemp(prefix='shopikaiss-shutdown-test-')
process = subprocess.Popen([str(exe), '--dossier', folder], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, encoding='utf-8')
frames = queue.Queue()

def read():
    for line in process.stdout:
        frames.put(json.loads(line))

threading.Thread(target=read, daemon=True).start()
try:
    process.stdin.write(json.dumps({'version': 1, 'kind': 'request', 'id': 'probe',
        'command': 'pair', 'arguments': {'origin': f'http://127.0.0.1:{server.server_port}',
        'code': 'TEST-ONLY', 'model': 'Synthetic', 'app_version': 'shutdown-test'}}) + '\n')
    process.stdin.flush()
    while frames.get(timeout=30).get('id') != 'probe':
        pass
    assert received.wait(2), 'The probe did not open an HTTP connection'
    start = time.perf_counter()
    process.stdin.close()
    code = process.wait(timeout=5)
    assert code == 0, f'Unexpected exit code {code}'
    print(f'PASS: Release host exited after HTTP keep-alive and EOF in {(time.perf_counter()-start)*1000:.0f} ms')
finally:
    if process.poll() is None:
        # This process owns only the temporary test database, never user data.
        process.kill()
        process.wait()
    server.shutdown()
    server.server_close()
