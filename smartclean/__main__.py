import argparse
import json
import mimetypes
import os
import secrets
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .config import Settings
from .db import Database
from .engine import Engine
from .service import Service

WEB = Path(__file__).parent / 'web'

def make_server(service, port=8765):
    token = secrets.token_urlsafe(32)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def send(self, value, status=200, content_type='application/json; charset=utf-8'):
            body = json.dumps(value, ensure_ascii=False).encode() if isinstance(value, (dict, list)) else value
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(body)

        def safe_host(self):
            return self.headers.get('Host') in (f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}')

        def do_GET(self):
            if not self.safe_host():
                self.send({'error': 'Invalid host'}, 403)
                return
            try:
                path = urlparse(self.path)
                query = {k: v[0] for k, v in parse_qs(path.query).items()}
                if path.path == '/api/health':
                    self.send({'app': 'SmartClean', 'version': '0.1.1'})
                elif path.path == '/api/session':
                    self.send({'token': token})
                elif path.path == '/api/settings':
                    self.send(service.settings.get())
                elif path.path == '/api/status':
                    self.send(service.status())
                elif path.path == '/api/catalog':
                    self.send(service.catalog(query))
                elif path.path == '/api/duplicates':
                    self.send(service.duplicates(int(query.get('offset', 0))))
                elif path.path == '/api/similar':
                    self.send(service.similar(int(query.get('threshold', 5))))
                elif path.path == '/api/labels':
                    self.send(service.labels())
                elif path.path == '/api/volumes':
                    self.send(service.volumes())
                elif path.path.startswith('/api/preview/'):
                    file = service.preview(int(path.path.rsplit('/', 1)[1]))
                    self.send(file.read_bytes(), content_type='image/jpeg')
                elif path.path in ('/', '/app.js', '/style.css', '/favicon.svg'):
                    file = WEB / ('index.html' if path.path == '/' else path.path[1:])
                    self.send(file.read_bytes(), content_type={'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml'}[file.suffix] + '; charset=utf-8')
                else:
                    self.send({'error': 'Not found'}, 404)
            except (ValueError, TypeError) as exc:
                self.send({'error': str(exc)}, 400)
            except FileNotFoundError as exc:
                self.send({'error': str(exc)}, 404)
            except Exception as exc:
                self.send({'error': str(exc)}, 500)

        def do_POST(self):
            origin = self.headers.get('Origin')
            if not self.safe_host() or self.headers.get('X-SmartClean-Token') != token or origin not in (None, f'http://127.0.0.1:{self.server.server_port}', f'http://localhost:{self.server.server_port}'):
                self.send({'error': 'Invalid local session'}, 403)
                return
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size < 65536:
                    raise ValueError('Invalid request size')
                body = json.loads(self.rfile.read(size))
                path = urlparse(self.path).path
                if path == '/api/settings':
                    with service.engine.lock:
                        if service.engine.thread and service.engine.thread.is_alive():
                            raise ValueError('Остановите текущую задачу перед изменением источников')
                        self.send(service.settings.save(body))
                elif path == '/api/jobs':
                    self.send(service.engine.start(body.get('kind', 'scan')), 202)
                elif path == '/api/jobs/cancel':
                    self.send(service.engine.cancel() or {})
                elif path == '/api/labels':
                    self.send(service.label(int(body['file_id']), body['category'], body['value'], body.get('remove', False)))
                else:
                    self.send({'error': 'Not found'}, 404)
            except (ValueError, TypeError, KeyError) as exc:
                self.send({'error': str(exc)}, 400)
            except FileNotFoundError as exc:
                self.send({'error': str(exc)}, 404)
            except Exception as exc:
                self.send({'error': str(exc)}, 500)

    class Server(ThreadingHTTPServer):
        daemon_threads = True
        request_queue_size = 32
    return Server(('127.0.0.1', port), Handler)

def main():
    parser = argparse.ArgumentParser(description='SmartClean local media catalog')
    parser.add_argument('--data-dir', default=os.environ.get('SMARTCLEAN_DATA_DIR', '.local'))
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    settings = Settings(args.data_dir)
    if sys.stderr is None:
        sys.stderr = (settings.data / 'server-error.log').open('a', encoding='utf-8', buffering=1)
    if sys.stdout is None:
        sys.stdout = (settings.data / 'server.log').open('a', encoding='utf-8', buffering=1)
    db = Database(settings.data / 'catalog.sqlite3')
    engine = Engine(db, settings)
    server = make_server(Service(db, settings, engine), args.port)
    print(f'SmartClean: http://127.0.0.1:{server.server_port}', flush=True)
    print(f'Data: {settings.data}. No scan starts automatically.', flush=True)
    try:
        server.serve_forever(poll_interval=.25)
    except KeyboardInterrupt:
        pass
    finally:
        engine.cancel()
        if engine.thread:
            engine.thread.join(timeout=45)
        server.server_close()

if __name__ == '__main__':
    main()
