"""Small reproducible IO/cache measurement, never scans user media."""
import json
import tempfile
import time
from pathlib import Path

from smartclean.config import Settings
from smartclean.db import Database
from smartclean.engine import Engine

def main():
    with tempfile.TemporaryDirectory(prefix='smartclean-benchmark-') as temporary:
        base = Path(temporary)
        root = base / 'media'
        root.mkdir()
        for i in range(100):
            content = str(i).encode().ljust(256, b'x') * 1024
            (root / f'{i}.mp4').write_bytes(content)
            (root / f'{i}-copy.mp4').write_bytes(content)
        settings = Settings(base / 'state')
        settings.save(settings.get() | {'roots': [str(root)]})
        engine = Engine(Database(settings.data / 'catalog.sqlite3'), settings)
        results = []
        for repeat in range(2):
            started = time.perf_counter()
            engine.start()
            engine.thread.join()
            result = engine.snapshot()
            if result['state'] != 'completed':
                raise RuntimeError(result)
            results.append({'pass': repeat + 1, 'seconds': round(time.perf_counter() - started, 3), 'stats': result['stats']})
        report = {'fixture': '200 synthetic files, 100 duplicate pairs, 50 MiB logical data; OS cache applies; not a real-drive benchmark', 'results': results}
        destination = Path('output/benchmark.json')
        destination.parent.mkdir(exist_ok=True)
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(report, ensure_ascii=False))

if __name__ == '__main__':
    main()
