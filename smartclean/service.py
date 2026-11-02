import json
import hashlib
import os
import shutil
import threading
import time
import uuid
from collections import defaultdict
from pathlib import Path

from .config import Scope
from .engine import BKTree, unchanged
from . import media

def public(row):
    value = dict(row)
    value['metadata'] = json.loads(value.get('metadata') or '{}')
    return value


class Service:
    def __init__(self, database, settings, engine):
        self.database, self.settings, self.engine = database, settings, engine
        self.preview_lock = threading.Lock()
        self.totals_lock = threading.Lock()
        self.totals_cache = None
        self.scope_lock = threading.RLock()
        self.scope_revision = None
        with self.database.connect() as db:
            self.scoped(db)

    def scoped(self, db):
        config = self.settings.get()
        db.create_function('unicode_lower', 1, lambda s: s.casefold() if s else '')
        revision = self.settings.file.stat().st_mtime_ns
        with self.scope_lock:
            if self.scope_revision != revision:
                scope = Scope(config, self.settings.data)
                fingerprint = hashlib.sha256(json.dumps([scope.roots, scope.excluded, sorted(scope.names)],ensure_ascii=False).encode()).hexdigest()
                previous = db.execute("SELECT value FROM application_meta WHERE key='scope'").fetchone()
                if previous is None or previous[0] != fingerprint:
                    db.create_function('scope_visible', 1, scope.contains)
                    db.execute('UPDATE files SET visible=scope_visible(path) WHERE visible<>scope_visible(path)')
                    db.execute("INSERT OR REPLACE INTO application_meta VALUES('scope',?)", (fingerprint,))
                self.scope_revision = revision
        return 'present=1 AND visible=1 AND size>=' + str(config['min_size'])

    def status(self):
        current = self.engine.snapshot()
        revision = (self.settings.file.stat().st_mtime_ns, current and current['id'],
                    current and current['state'], current and current['stats']['discovered'],
                    current and current['stats']['analyzed'])
        with self.database.connect() as db:
            with self.totals_lock:
                cached = self.totals_cache
                running = current and current['state'] in ('running', 'cancelling')
                if cached and (cached[0] == revision or running and time.monotonic() - cached[1] < 5):
                    totals = cached[2]
                else:
                    active = self.scoped(db)
                    totals = dict(db.execute(f'''SELECT COUNT(*) AS files,COALESCE(SUM(size),0) AS bytes,
                     COALESCE(SUM(kind='image'),0) AS images,COALESCE(SUM(kind='video'),0) AS videos,
                     COALESCE(SUM(analysis_key IS NOT NULL),0) AS analyzed FROM files INDEXED BY file_summary WHERE {active}''').fetchone())
                    self.totals_cache = revision, time.monotonic(), totals
            recent = [dict(r) for r in db.execute('SELECT * FROM jobs ORDER BY started DESC LIMIT 8')]
            errors = [dict(r) for r in db.execute('SELECT * FROM errors ORDER BY id DESC LIMIT 30')]
        for job in recent:
            job['stats'] = json.loads(job['stats'])
        last_scan = next((j for j in recent if j['kind'] in ('scan','resume')), None)
        resume_available = bool(last_scan and last_scan['state'] in ('interrupted','cancelled','failed')
                                and last_scan['stats'].get('sources_total')
                                and last_scan['stats'].get('sources_done') == last_scan['stats']['sources_total']
                                and not (current and current['state'] in ('running','cancelling')))
        return {'totals': totals, 'job': current, 'recent': recent, 'errors': errors,
                'resume_available': resume_available,
                'capabilities': media.capabilities(self.settings.get())}

    def catalog(self, query):
        take = min(100, max(1, int(query.get('limit', 60))))
        page = max(0, int(query.get('page', 0)))
        params = []
        with self.database.connect() as db:
            conditions = [self.scoped(db)]
            if query.get('q'):
                conditions.append("(instr(unicode_lower(path),unicode_lower(?))>0 OR id IN (SELECT file_id FROM labels WHERE instr(unicode_lower(value),unicode_lower(?))>0))")
                params += [query['q'], query['q']]
            if query.get('kind'):
                conditions.append('kind=?')
                params.append(query['kind'])
            if query.get('ext'):
                conditions.append('ext=?')
                params.append(query['ext'].lower())
            if query.get('aspect'):
                conditions.append("json_extract(metadata,'$.aspect')=?")
                params.append(query['aspect'])
            if query.get('label'):
                conditions.append('id IN (SELECT file_id FROM labels WHERE value=?)')
                params.append(query['label'])
            where = ' AND '.join(conditions)
            count_index = '' if any(query.get(k) for k in ('q','ext','aspect','label')) else ' INDEXED BY file_summary'
            total = db.execute(f'SELECT COUNT(*) FROM files{count_index} WHERE {where}', params).fetchone()[0]
            sorting = {'largest': 'size DESC,id', 'newest': 'mtime_ns DESC,id', 'name': 'path'}.get(query.get('sort'), 'size DESC,id')
            rows = [public(r) for r in db.execute(f'SELECT * FROM files WHERE {where} ORDER BY {sorting} LIMIT ? OFFSET ?', (*params, take, page * take))]
            for row in rows:
                row['labels'] = [dict(r) for r in db.execute('SELECT category,value FROM labels WHERE file_id=? ORDER BY category,value', (row['id'],))]
            extensions = [r[0] for r in db.execute(f'SELECT DISTINCT ext FROM files INDEXED BY file_extensions WHERE {self.scoped(db)} ORDER BY ext')]
        return {'files': rows, 'total': total, 'page': page, 'limit': take, 'extensions': extensions}

    def duplicates(self, offset=0):
        # A report is evidence at scan time; any later operation would require a new validation.
        with self.database.connect() as db:
            active = self.scoped(db)
            total = db.execute(f'SELECT COUNT(*) FROM (SELECT digest,size FROM files WHERE {active} AND digest IS NOT NULL GROUP BY digest,size HAVING COUNT(*)>1)').fetchone()[0]
            keys = db.execute(f'''SELECT digest,size FROM files WHERE {active} AND digest IS NOT NULL
             GROUP BY digest,size HAVING COUNT(*)>1 ORDER BY size DESC LIMIT 30 OFFSET ?''', (max(0, offset),)).fetchall()
            groups = []
            for key in keys:
                rows = [public(r) for r in db.execute(f'SELECT * FROM files WHERE {active} AND digest=? AND size=? ORDER BY path', (key['digest'], key['size']))]
                physical = {(r['dev'], r['ino']) for r in rows}
                has_links = any(r['nlink'] > 1 or r['ino'] == '0' for r in rows)
                groups.append({'digest': key['digest'], 'size': key['size'], 'files': rows,
                               'physical_copies': len(physical), 'has_hardlinks': has_links,
                               'duplicate_logical_bytes': max(0, len(physical) - 1) * key['size'],
                               'verified_at': 'last_scan'})
        return {'groups': groups, 'total': total, 'offset': offset,
                'note': 'Размер повторного содержимого — оценка. Жёсткие ссылки, сжатие, sparse-файлы и состояние диска влияют на фактически освобождаемое место.'}

    def similar(self, threshold=5):
        threshold = max(0, min(10, threshold))
        trees = defaultdict(BKTree)
        pairs = []
        count = 0
        with self.database.connect() as db:
            active = self.scoped(db)
            eligible = f"{active} AND kind='image' AND json_extract(metadata,'$.dhash') IS NOT NULL"
            total = db.execute(f'SELECT COUNT(*) FROM files WHERE {eligible}').fetchone()[0]
            rows = db.execute(f'SELECT * FROM files WHERE {eligible} ORDER BY id LIMIT 20000')
            for raw in rows:
                row = public(raw)
                value = int(row['metadata']['dhash'], 16)
                tree = trees[row['metadata'].get('aspect', '?')]
                for distance, other in tree.find(value, threshold):
                    if row['digest'] and row['digest'] == other['digest'] or (row['dev'], row['ino']) == (other['dev'], other['ino']):
                        continue
                    pairs.append({'distance': distance, 'files': [other, row]})
                    if len(pairs) >= 300:
                        return {'pairs': pairs, 'limited': True, 'processed': count, 'total': total, 'threshold': threshold}
                tree.add(value, row)
                count += 1
        return {'pairs': pairs, 'limited': total > count, 'processed': count, 'total': total, 'threshold': threshold}

    def labels(self):
        with self.database.connect() as db:
            active = self.scoped(db)
            return [dict(r) for r in db.execute(f'''SELECT category,value,COUNT(*) AS count FROM labels
             JOIN files ON file_id=files.id WHERE {active} GROUP BY category,value ORDER BY category,value''')]

    def label(self, file_id, category, value, remove=False):
        if category not in ('person', 'place', 'object', 'event', 'tag') or not isinstance(value, str) or not 0 < len(value.strip()) <= 120:
            raise ValueError('Invalid label')
        self.file(file_id)
        with self.database.connect() as db:
            if remove:
                db.execute('DELETE FROM labels WHERE file_id=? AND category=? AND value=?', (file_id, category, value.strip()))
            else:
                db.execute('INSERT OR IGNORE INTO labels VALUES(?,?,?)', (file_id, category, value.strip()))
        return {'ok': True}

    def file(self, file_id):
        with self.database.connect() as db:
            row = db.execute('SELECT * FROM files WHERE id=? AND present=1', (int(file_id),)).fetchone()
        if row is None or not Scope(self.settings.get(), self.settings.data).allowed(row['path']):
            raise FileNotFoundError('File is outside the configured scope')
        if not unchanged(row):
            raise FileNotFoundError('File changed or is offline. Scan the source again.')
        return row

    def preview(self, file_id):
        row = self.file(file_id)
        cache = self.settings.data / 'thumbs'
        cache.mkdir(exist_ok=True)
        destination = cache / (media.cache_key(row) + '.jpg')
        with self.preview_lock:
            if not destination.exists():
                temporary = cache / (uuid.uuid4().hex + '.jpg')
                try:
                    if not media.thumbnail(row['path'], row['kind'], self.settings.get(), temporary):
                        raise FileNotFoundError('Preview decoder is unavailable')
                    self.file(file_id)
                    os.replace(temporary, destination)
                finally:
                    temporary.unlink(missing_ok=True)
        return destination

    def volumes(self):
        if os.name == 'nt':
            import ctypes
            bits = ctypes.windll.kernel32.GetLogicalDrives()
            paths = [f'{chr(65+i)}:\\' for i in range(26) if bits & (1 << i)]
        else:
            paths = ['/']
        result = []
        for path in paths:
            try:
                usage = shutil.disk_usage(path)
                result.append({'path': path, 'total': usage.total, 'free': usage.free})
            except OSError:
                continue
        return result
