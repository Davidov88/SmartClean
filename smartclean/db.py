import sqlite3
from contextlib import contextmanager

SCHEMA = '''
CREATE TABLE IF NOT EXISTS files (
 id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, root TEXT NOT NULL,
 kind TEXT NOT NULL, ext TEXT NOT NULL, size INTEGER NOT NULL,
 mtime_ns INTEGER NOT NULL, ctime_ns INTEGER NOT NULL, dev TEXT NOT NULL, ino TEXT NOT NULL,
 nlink INTEGER NOT NULL, seen TEXT NOT NULL, present INTEGER NOT NULL DEFAULT 1,
 quick TEXT, digest TEXT, metadata TEXT, analysis_key TEXT, visible INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS file_size ON files(present,size);
CREATE INDEX IF NOT EXISTS file_digest ON files(digest,size);
CREATE INDEX IF NOT EXISTS file_root ON files(root,seen);
CREATE INDEX IF NOT EXISTS file_catalog_size ON files(present,size DESC,id);
CREATE INDEX IF NOT EXISTS file_catalog_date ON files(present,mtime_ns DESC,id);
CREATE INDEX IF NOT EXISTS file_summary ON files(present,visible,kind,size,analysis_key);
CREATE INDEX IF NOT EXISTS file_extensions ON files(present,visible,ext,size);
CREATE INDEX IF NOT EXISTS file_hash_candidates ON files(present,visible,size,quick);
CREATE TABLE IF NOT EXISTS jobs (
 id TEXT PRIMARY KEY, kind TEXT NOT NULL, state TEXT NOT NULL,
 phase TEXT NOT NULL, started REAL NOT NULL, finished REAL,
 stats TEXT NOT NULL, error TEXT
);
CREATE TABLE IF NOT EXISTS errors (
 id INTEGER PRIMARY KEY, job TEXT NOT NULL, path TEXT NOT NULL, message TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS labels (
 file_id INTEGER NOT NULL REFERENCES files(id), category TEXT NOT NULL,
 value TEXT NOT NULL, UNIQUE(file_id,category,value)
);
CREATE INDEX IF NOT EXISTS labels_lookup ON labels(category,value);
CREATE TABLE IF NOT EXISTS application_meta (key TEXT PRIMARY KEY,value TEXT NOT NULL);
PRAGMA user_version=1;
'''

class Database:
    def __init__(self, path):
        self.path = str(path)
        with self.connect() as db:
            db.execute('PRAGMA journal_mode=WAL')
            columns = {row[1] for row in db.execute('PRAGMA table_info(files)')}
            if columns and 'visible' not in columns:
                db.execute('ALTER TABLE files ADD COLUMN visible INTEGER NOT NULL DEFAULT 1')
            extension_columns = {r[2] for r in db.execute('PRAGMA index_info(file_extensions)')}
            if extension_columns and 'size' not in extension_columns:
                db.execute('DROP INDEX file_extensions')
            db.executescript(SCHEMA)
            db.execute("UPDATE jobs SET state='interrupted' WHERE state IN ('running','cancelling')")

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()
