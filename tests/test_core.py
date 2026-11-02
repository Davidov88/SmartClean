import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from smartclean.config import Settings, Scope, native
from smartclean.db import Database
from smartclean.engine import Engine, Cancelled, hash_file, BKTree
from smartclean.service import Service
from smartclean.__main__ import make_server


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.root = self.base / 'media'
        self.root.mkdir()
        self.settings = Settings(self.base / 'state')
        self.settings.save(self.settings.get() | {'roots': [str(self.root)]})
        self.db = Database(self.settings.data / 'test.sqlite3')
        self.engine = Engine(self.db, self.settings)
        self.service = Service(self.db, self.settings, self.engine)

    def tearDown(self):
        self.engine.cancel()
        if self.engine.thread:
            self.engine.thread.join(10)
        self.tmp.cleanup()

    def run_job(self, kind='scan'):
        self.engine.start(kind)
        self.engine.thread.join(20)
        self.assertFalse(self.engine.thread.is_alive())
        result = self.engine.snapshot()
        self.assertEqual(result['state'], 'completed', result)
        return result

    def write(self, name, data=b'photo-data'):
        path = self.root / name
        path.parent.mkdir(exist_ok=True, parents=True)
        path.write_bytes(data)
        return path

    def test_exact_duplicates_cache_and_invalidation(self):
        self.write('a.jpg', b'a' * 300000)
        second = self.write('sub/renamed.png', b'a' * 300000)
        self.write('different.jpg', b'b' * 300000)
        first = self.run_job()
        self.assertEqual(first['stats']['full_hashed'], 3)
        self.assertEqual(self.service.duplicates()['total'], 1)
        repeated = self.run_job()
        self.assertEqual(repeated['stats']['full_hashed'], 0)
        self.assertEqual(repeated['stats']['cached'], 3)
        second.write_bytes(b'z' * 300000)
        self.run_job()
        self.assertEqual(self.service.duplicates()['total'], 0)

    def test_partial_collision_does_not_confirm_duplicate(self):
        a = bytearray(b'x' * 2 * 1024 * 1024)
        b = bytearray(a)
        b[200000] = 89  # Outside the sampled beginning/middle/end.
        self.write('a.mov', a)
        self.write('b.mov', b)
        result = self.run_job()
        self.assertEqual(result['stats']['full_hashed'], 2)
        self.assertEqual(self.service.duplicates()['total'], 0)

    def test_exclusion_before_traversal_and_no_prefix_confusion(self):
        excluded = self.root / 'private'
        self.write('private/secret.mp4')
        self.write('private-extra/visible.mp4')
        self.settings.save(self.settings.get() | {'exclude_paths': [str(excluded)]})
        original = os.scandir
        def guarded(path):
            self.assertNotEqual(os.path.normcase(str(path)), os.path.normcase(str(excluded)))
            return original(path)
        with patch('smartclean.engine.os.scandir', side_effect=guarded):
            self.run_job()
        self.assertEqual(self.service.catalog({})['total'], 1)

    def test_new_exclusion_hides_already_indexed_data(self):
        self.write('a.jpg')
        self.write('private/b.jpg')
        self.run_job()
        self.assertEqual(self.service.duplicates()['total'], 1)
        self.settings.save(self.settings.get() | {'exclude_paths': [str(self.root / 'private')]})
        self.assertEqual(self.service.catalog({})['total'], 1)
        self.assertEqual(self.service.duplicates()['total'], 0)

    def test_missing_and_offline_sources(self):
        file = self.write('a.jpg')
        self.run_job()
        file.unlink()
        self.run_job()
        self.assertEqual(self.service.catalog({})['total'], 0)
        self.write('b.jpg')
        self.run_job()
        moved = self.base / 'disconnected'
        self.root.rename(moved)
        result = self.run_job()
        self.assertEqual(result['stats']['errors'], 1)
        self.assertEqual(self.service.catalog({})['total'], 1)
        moved.rename(self.root)

    def test_hardlinks_are_not_counted_as_independent_copies(self):
        a = self.write('a.jpg')
        try:
            os.link(a, self.root / 'b.jpg')
        except OSError:
            self.skipTest('Hardlinks unavailable')
        self.run_job()
        group = self.service.duplicates()['groups'][0]
        self.assertEqual(group['physical_copies'], 1)
        self.assertEqual(group['duplicate_logical_bytes'], 0)
        self.assertTrue(group['has_hardlinks'])

    def test_changed_file_is_not_served_or_hashed(self):
        a = self.write('a.jpg')
        self.run_job()
        row = self.service.file(self.service.catalog({})['files'][0]['id'])
        a.write_bytes(b'changed')
        with self.assertRaises(OSError):
            hash_file(row, False, lambda: None)
        with self.assertRaises(FileNotFoundError):
            self.service.file(row['id'])

    def test_cancellation_during_hash_never_returns_digest(self):
        self.write('a.jpg', b'a' * 10_000_000)
        self.run_job()
        row = self.service.file(self.service.catalog({})['files'][0]['id'])
        calls = 0
        def cancel():
            nonlocal calls
            calls += 1
            if calls == 3:
                raise Cancelled()
        with self.assertRaises(Cancelled):
            hash_file(row, False, cancel)

    def test_labels_and_sql_input_are_data(self):
        self.write('a.jpg')
        self.run_job()
        file = self.service.catalog({})['files'][0]
        value = "Иван'; DROP TABLE files; --"
        self.service.label(file['id'], 'person', value)
        self.assertEqual(self.service.catalog({'q': value})['total'], 1)
        self.assertEqual(self.service.catalog({'q': 'ИВАН'})['total'], 1)
        self.assertEqual(self.service.labels()[0]['value'], value)
        self.service.label(file['id'], 'person', value, remove=True)
        self.assertEqual(self.service.labels(), [])

    def test_images_metadata_preview_and_similarity(self):
        try:
            from PIL import Image, ImageDraw
        except ImportError:
            self.skipTest('Pillow not installed')
        image = Image.new('RGB', (640, 360), 'navy')
        draw = ImageDraw.Draw(image)
        draw.rectangle((60, 50, 270, 300), fill='orange')
        image.save(self.root / 'one.jpg', quality=95)
        image.save(self.root / 'two.jpg', quality=65)
        self.run_job()
        self.run_job('analyze')
        files = self.service.catalog({'aspect': '16:9'})['files']
        self.assertEqual(len(files), 2)
        self.assertEqual(files[0]['metadata']['width'], 640)
        self.assertEqual(len(self.service.similar()['pairs']), 1)
        preview = self.service.preview(files[0]['id'])
        with Image.open(preview) as thumb:
            self.assertLessEqual(thumb.width, 480)
        repeated = self.run_job('analyze')
        self.assertEqual(repeated['stats']['analyzed'], 0)

    def test_restart_marks_jobs_interrupted(self):
        with self.db.connect() as db:
            db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?)', ('old', 'scan', 'running', 'hashing', time.time(), None, '{}', None))
        Database(self.db.path)
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT state FROM jobs WHERE id='old'").fetchone()[0], 'interrupted')
            self.assertEqual(db.execute("SELECT phase FROM jobs WHERE id='old'").fetchone()[0], 'hashing')

    def test_resume_hashing_reuses_digests_without_inventory(self):
        self.write('a.mp4', b'a' * 2_000_000)
        self.write('b.mp4', b'a' * 2_000_000)
        self.run_job()
        with self.db.connect() as db:
            db.execute('UPDATE files SET digest=NULL WHERE id=(SELECT min(id) FROM files)')
            db.execute("UPDATE jobs SET state='interrupted'")
        with patch.object(self.engine, 'inventory', side_effect=AssertionError('Must not rescan folders')):
            result = self.run_job('resume')
        self.assertEqual(result['stats']['full_hashed'], 1)
        self.assertEqual(result['stats']['sources_done'], 1)
        self.assertEqual(self.service.duplicates()['total'], 1)

    def test_resume_rejects_incomplete_inventory(self):
        self.write('a.jpg')
        self.run_job()
        with self.db.connect() as db:
            job = db.execute('SELECT id,stats FROM jobs LIMIT 1').fetchone()
            stats = json.loads(job['stats'])
            stats['sources_done'] = 0
            db.execute("UPDATE jobs SET state='interrupted',stats=? WHERE id=?", (json.dumps(stats),job['id']))
        with self.assertRaises(ValueError):
            self.engine.start('resume')

    @unittest.skipUnless(os.name == 'nt', 'Windows extended paths')
    def test_windows_long_paths_are_indexed_and_hashed(self):
        folder = self.root
        for i in range(6):
            folder /= ('long-folder-' + str(i) + '-' + 'x' * 35)
        Path(native(folder)).mkdir(parents=True)
        Path(native(folder / 'one.jpg')).write_bytes(b'long path image')
        self.write('copy.jpg', b'long path image')
        result = self.run_job()
        self.assertEqual(result['stats']['errors'], 0)
        self.assertEqual(self.service.catalog({})['total'], 2)
        self.assertEqual(self.service.duplicates()['total'], 1)
        # tempfile's Windows cleanup itself doesn't consistently use extended paths.
        Path(native(folder / 'one.jpg')).unlink()
        while folder != self.root:
            Path(native(folder)).rmdir()
            folder = folder.parent

    def test_http_requires_local_session_for_mutations(self):
        server = make_server(self.service, 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f'http://127.0.0.1:{server.server_port}'
        try:
            with urlopen(url + '/api/session') as response:
                token = json.load(response)['token']
            request = Request(url + '/api/settings', data=b'{}', headers={'Content-Type': 'application/json'})
            with self.assertRaises(HTTPError) as result:
                urlopen(request)
            self.assertEqual(result.exception.code, 403)
            result.exception.close()
            request.add_header('X-SmartClean-Token', token)
            with urlopen(request) as response:
                self.assertEqual(response.status, 200)
            with self.assertRaises(HTTPError) as missing:
                urlopen(url + '/../../pyproject.toml')
            missing.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)

    def test_bktree_matches_exhaustive_distance(self):
        tree = BKTree()
        values = [0, 1, 3, 7, 15, 42, 255, 1024, 65535]
        for v in values:
            tree.add(v, v)
        for query in values:
            actual = sorted(v for _, v in tree.find(query, 2))
            self.assertEqual(actual, sorted(v for v in values if (query ^ v).bit_count() <= 2))

if __name__ == '__main__':
    unittest.main()
