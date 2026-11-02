import hashlib
import json
import os
import stat
import threading
import time
import uuid
from collections import defaultdict
from pathlib import Path

from .config import IMAGES, VIDEOS, Scope, canonical, normalized, native, is_link
from . import media


class Cancelled(Exception):
    pass


def identity(st):
    return st.st_size, st.st_mtime_ns, st.st_ctime_ns, str(st.st_dev), str(st.st_ino)


def row_identity(row):
    return tuple(row[k] for k in ('size', 'mtime_ns', 'ctime_ns', 'dev', 'ino'))


def handle_identity(st):
    # On Windows, Python versions/filesystems may expose different ctime semantics
    # for path stat and fstat. Compare stable handle fields; also check path before/after.
    return st.st_size, st.st_mtime_ns, st.st_dev, st.st_ino


def unchanged(row):
    try:
        st = os.stat(native(row['path']), follow_symlinks=False)
        return stat.S_ISREG(st.st_mode) and not is_link(st) and identity(st) == row_identity(row)
    except OSError:
        return False


def hash_file(row, partial, check):
    """Never accept a digest if identity changed during the read."""
    check()
    before = os.stat(native(row['path']), follow_symlinks=False)
    if is_link(before) or identity(before) != row_identity(row):
        raise OSError('File changed since inventory; scan again')
    digest = hashlib.sha256()
    with open(native(row['path']), 'rb') as stream:
        opened = os.fstat(stream.fileno())
        if handle_identity(opened) != handle_identity(before):
            raise OSError('File replaced before hashing')
        if partial:
            size = before.st_size
            digest.update(str(size).encode())
            for offset in sorted({0, max(0, size // 2 - 32768), max(0, size - 65536)}):
                check()
                stream.seek(offset)
                digest.update(stream.read(65536))
        else:
            while block := stream.read(4 * 1024 * 1024):
                check()
                digest.update(block)
        after = os.fstat(stream.fileno())
    if identity(opened) != identity(after) or not unchanged(row):
        raise OSError('File changed during hashing; result discarded')
    return digest.hexdigest()


class Engine:
    def __init__(self, database, settings):
        self.database, self.settings = database, settings
        self.lock = threading.RLock()
        self.stop = threading.Event()
        self.thread = None
        self.current = None
        self.last_flush = 0

    def start(self, kind='scan'):
        if kind not in ('scan', 'analyze', 'resume'):
            raise ValueError('Unknown job type')
        with self.lock:
            if self.thread and self.thread.is_alive():
                raise ValueError('A job is already running')
            settings = self.settings.get()
            if not settings['roots']:
                raise ValueError('Сначала добавьте папки в настройках')
            resume_stats = None
            saved_full_hashes = 0
            if kind == 'resume':
                with self.database.connect() as db:
                    previous = db.execute("SELECT * FROM jobs WHERE kind IN ('scan','resume') ORDER BY started DESC LIMIT 1").fetchone()
                    saved_full_hashes = db.execute('SELECT COUNT(*) FROM files INDEXED BY file_digest WHERE digest IS NOT NULL').fetchone()[0]
                if previous:
                    resume_stats = json.loads(previous['stats'])
                if not resume_stats or not resume_stats.get('sources_total') or resume_stats.get('sources_done') != resume_stats['sources_total']:
                    raise ValueError('Обход источников не завершён. Запустите обычное сканирование.')
            self.stop.clear()
            self.current = {'id': uuid.uuid4().hex, 'kind': kind, 'state': 'running',
                            'phase': 'inventory' if kind == 'scan' else 'hashing' if kind == 'resume' else 'metadata', 'started': time.time(),
                            'finished': None, 'error': None,
                            'stats': {'discovered': 0, 'new': 0, 'changed': 0, 'cached': 0,
                                      'quick_hashed': 0, 'full_hashed': 0, 'analyzed': 0,
                                      'errors': 0, 'skipped': 0, 'current': '', 'folders': 0,
                                      'entries': 0, 'source': '', 'sources_done': 0,
                                      'sources_total': len(settings['roots']), 'updated': time.time()}}
            self.current['stats']['saved_full_hashes'] = saved_full_hashes
            if resume_stats:
                for key in ('discovered', 'folders', 'entries', 'sources_done', 'sources_total'):
                    self.current['stats'][key] = resume_stats.get(key, 0)
                self.current['stats']['resumed_from'] = previous['id']
            self.flush()
            self.thread = threading.Thread(target=self._run, args=(settings,), daemon=True, name='smartclean-job')
            self.thread.start()
            return self.snapshot()

    def cancel(self):
        with self.lock:
            if self.thread and self.thread.is_alive():
                self.stop.set()
                self.current['state'] = 'cancelling'
            return self.snapshot()

    def snapshot(self):
        with self.lock:
            return json.loads(json.dumps(self.current)) if self.current else None

    def check(self):
        if self.stop.is_set():
            raise Cancelled()

    def flush(self):
        with self.lock:
            j = self.current
            with self.database.connect() as db:
                db.execute('INSERT OR REPLACE INTO jobs VALUES(?,?,?,?,?,?,?,?)',
                           (j['id'], j['kind'], j['state'], j['phase'], j['started'], j['finished'], json.dumps(j['stats']), j['error']))
            self.last_flush = time.monotonic()

    def progress(self, **values):
        with self.lock:
            values['updated'] = time.time()
            self.current['stats'].update(values)
            if time.monotonic() - self.last_flush > .75:
                self.flush()

    def increment(self, name, value=1):
        with self.lock:
            self.current['stats'][name] += value

    def error(self, path, exc):
        self.increment('errors')
        with self.database.connect() as db:
            db.execute('INSERT INTO errors(job,path,message) VALUES(?,?,?)', (self.current['id'], str(path), str(exc)[:1000]))

    def _run(self, settings):
        self.scope = Scope(settings, self.settings.data)
        try:
            if self.current['kind'] == 'scan':
                self.inventory(settings)
            if self.current['kind'] in ('scan', 'resume'):
                self.current['phase'] = 'hashing'
                self.flush()
                self.hash_candidates()
            else:
                self.analyze(settings)
            self.check()
            self.current['state'] = 'completed'
            self.current['phase'] = 'done'
        except Cancelled:
            self.current['state'] = 'cancelled'
        except Exception as exc:
            self.current['state'] = 'failed'
            self.current['error'] = str(exc)
        finally:
            self.current['finished'] = time.time()
            self.current['stats']['current'] = ''
            self.flush()

    def inventory(self, settings):
        roots = sorted(set(self.scope.roots), key=len)
        selected = []
        for root in roots:
            if not any(os.path.commonpath([root, r]) == r for r in selected if os.path.splitdrive(root)[0] == os.path.splitdrive(r)[0]):
                selected.append(root)
        for root in selected:
            self.check()
            if not self.scope.allowed(root):
                self.error(root, 'Source is excluded')
                continue
            try:
                root_st = os.stat(root, follow_symlinks=False)
                if not stat.S_ISDIR(root_st.st_mode) or is_link(root_st) or os.path.islink(root):
                    raise OSError('Source must be an existing directory, not a link or junction')
            except OSError as exc:
                self.error(root, exc)
                continue
            root_ok = True
            pending = []
            stack = [root]
            while stack:
                self.check()
                folder = stack.pop()
                if not self.scope.allowed(folder):
                    continue
                self.increment('folders')
                self.progress(current=normalized(folder), source=root)
                try:
                    with os.scandir(native(folder)) as entries:
                        for entry in entries:
                            self.check()
                            self.increment('entries')
                            if entry.name.casefold() in self.scope.names or entry.is_symlink():
                                self.increment('skipped')
                                continue
                            path = normalized(entry.path)
                            if not self.scope.contains(path):
                                continue
                            try:
                                st = entry.stat(follow_symlinks=False)
                                if is_link(st):
                                    self.increment('skipped')
                                    continue
                                if stat.S_ISDIR(st.st_mode):
                                    stack.append(path)
                                    continue
                                suffix = Path(entry.name).suffix.lower()
                                if not stat.S_ISREG(st.st_mode) or suffix not in IMAGES | VIDEOS or st.st_size < settings['min_size']:
                                    continue
                                # Windows DirEntry.stat can leave inode/device/nlink as zero.
                                # Use a full stat for media only, keeping directory discovery cheap.
                                if os.name == 'nt':
                                    st = os.stat(native(path), follow_symlinks=False)
                                pending.append((path, root, 'image' if suffix in IMAGES else 'video', suffix, st))
                                self.increment('discovered')
                                if len(pending) >= 200:
                                    self._store_inventory(pending)
                                    pending.clear()
                                self.progress(current=path, source=root)
                            except OSError as exc:
                                root_ok = False
                                self.error(entry.path, exc)
                except OSError as exc:
                    root_ok = False
                    self.error(folder, exc)
            self._store_inventory(pending)
            self.increment('sources_done')
            # Never invalidate an offline, partially readable or cancelled source.
            self.check()
            if root_ok:
                with self.database.connect() as db:
                    for row in db.execute('SELECT id,path FROM files WHERE root=? AND seen<>? AND present=1', (root, self.current['id'])).fetchall():
                        if self.scope.allowed(row['path']):
                            db.execute('UPDATE files SET present=0 WHERE id=?', (row['id'],))

    def _store_inventory(self, rows):
        with self.database.connect() as db:
            for path, root, kind, ext, st in rows:
                old = db.execute('SELECT * FROM files WHERE path=?', (path,)).fetchone()
                same = old is not None and row_identity(old) == identity(st)
                self.increment('cached' if same else 'changed' if old else 'new')
                if same and old['present'] and old['visible'] and old['root'] == root and old['nlink'] == st.st_nlink:
                    db.execute('UPDATE files SET seen=? WHERE id=?', (self.current['id'],old['id']))
                    continue
                db.execute('''INSERT INTO files(path,root,kind,ext,size,mtime_ns,ctime_ns,dev,ino,nlink,seen)
                 VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET
                 root=excluded.root,kind=excluded.kind,ext=excluded.ext,size=excluded.size,
                 mtime_ns=excluded.mtime_ns,ctime_ns=excluded.ctime_ns,dev=excluded.dev,ino=excluded.ino,
                 nlink=excluded.nlink,seen=excluded.seen,present=1,visible=1,
                 quick=CASE WHEN ? THEN files.quick ELSE NULL END,
                 digest=CASE WHEN ? THEN files.digest ELSE NULL END,
                 metadata=CASE WHEN ? THEN files.metadata ELSE NULL END,
                 analysis_key=CASE WHEN ? THEN files.analysis_key ELSE NULL END''',
                           (path, root, kind, ext, *identity(st), st.st_nlink, self.current['id'], same, same, same, same))

    def rows(self, extra='1', params=()):
        last = 0
        while True:
            with self.database.connect() as db:
                batch = db.execute(f'SELECT * FROM files WHERE present=1 AND id>? AND ({extra}) ORDER BY id LIMIT 200', (last, *params)).fetchall()
            if not batch:
                return
            for row in batch:
                last = row['id']
                if row['size'] >= self.scope.settings['min_size'] and self.scope.allowed(row['path']):
                    yield row

    def hash_candidates(self):
        for partial in (True, False):
            field = 'quick' if partial else 'digest'
            # Build candidate keys once per phase, not once per 200-file page.
            with self.database.connect() as db:
                if partial:
                    candidates = {r[0] for r in db.execute('SELECT size FROM files INDEXED BY file_hash_candidates WHERE present=1 AND visible=1 GROUP BY size HAVING COUNT(*)>1')}
                else:
                    candidates = {(r[0],r[1]) for r in db.execute('SELECT size,quick FROM files INDEXED BY file_hash_candidates WHERE present=1 AND visible=1 AND quick IS NOT NULL GROUP BY size,quick HAVING COUNT(*)>1')}
            pending = []
            small_digests = []
            committed = time.monotonic()
            def commit():
                nonlocal committed
                if pending:
                    with self.database.connect() as db:
                        db.executemany(f'UPDATE files SET {field}=? WHERE id=?', pending)
                        if small_digests:
                            db.executemany('UPDATE files SET digest=? WHERE id=?', small_digests)
                    pending.clear()
                    small_digests.clear()
                    committed = time.monotonic()
            try:
                for row in self.rows():
                    self.check()
                    key = row['size'] if partial else (row['size'],row['quick'])
                    if key not in candidates:
                        continue
                    self.progress(current=row['path'])
                    try:
                        if not unchanged(row):
                            with self.database.connect() as db:
                                db.execute('UPDATE files SET quick=NULL,digest=NULL,metadata=NULL,analysis_key=NULL WHERE id=?', (row['id'],))
                            raise OSError('File changed or went offline; rescan source')
                        if row[field]:
                            continue
                        # File open latency dominates small media on many Windows PCs.
                        # Hash small candidates fully once rather than opening them twice.
                        small = partial and row['size'] <= 1024 * 1024
                        value = hash_file(row, partial and not small, self.check)
                        pending.append((value, row['id']))
                        if small:
                            small_digests.append((value, row['id']))
                        if len(pending) >= 64 or time.monotonic() - committed >= 1:
                            commit()
                        self.increment('quick_hashed' if partial and not small else 'full_hashed')
                    except OSError as exc:
                        self.error(row['path'], exc)
            finally:
                commit()

    def analyze(self, settings):
        analysis_key = f"{media.VERSION}|{media.capabilities(settings)}|{settings['ffprobe']}"
        for row in self.rows():
            self.check()
            if row['analysis_key'] == analysis_key:
                self.increment('cached')
                continue
            self.progress(current=row['path'])
            try:
                if not unchanged(row):
                    raise OSError('File changed; rescan before analysis')
                value = media.probe(row['path'], row['kind'], settings)
                if not unchanged(row):
                    raise OSError('File changed during analysis')
                with self.database.connect() as db:
                    db.execute('UPDATE files SET metadata=?,analysis_key=? WHERE id=?', (json.dumps(value), analysis_key, row['id']))
                self.increment('analyzed')
            except Exception as exc:
                if isinstance(exc, Cancelled):
                    raise
                self.error(row['path'], exc)


class BKTree:
    """Hamming-distance lookup, avoiding an unconditional N² image comparison."""
    def __init__(self):
        self.root = None

    def add(self, value, row):
        node = (value, [row], {})
        if self.root is None:
            self.root = node
            return
        current = self.root
        while True:
            distance = (value ^ current[0]).bit_count()
            if distance == 0:
                current[1].append(row)
                return
            if distance not in current[2]:
                current[2][distance] = node
                return
            current = current[2][distance]

    def find(self, value, threshold):
        stack = [self.root] if self.root else []
        while stack:
            node = stack.pop()
            distance = (value ^ node[0]).bit_count()
            if distance <= threshold:
                for row in node[1]:
                    yield distance, row
            stack.extend(child for edge, child in node[2].items() if distance - threshold <= edge <= distance + threshold)
