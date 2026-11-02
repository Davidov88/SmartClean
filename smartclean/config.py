import json
import os
import tempfile
import threading
from pathlib import Path

IMAGES = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.tif', '.tiff', '.heic', '.heif', '.avif', '.dng', '.cr2', '.cr3', '.nef', '.arw'}
VIDEOS = {'.mp4', '.mov', '.mkv', '.avi', '.m4v', '.webm', '.mts', '.m2ts', '.3gp', '.mpg', '.mpeg', '.wmv', '.vob', '.ts'}
DEFAULTS = {
    'roots': [], 'exclude_paths': [],
    'exclude_names': ['$recycle.bin', 'system volume information', '.git', 'node_modules', '.venv', '__pycache__', '.smartclean-quarantine'],
    'system_exclusions': True, 'min_size': 1,
    'ffprobe': '', 'ffmpeg': '',
}

def canonical(path):
    return os.path.normcase(os.path.realpath(os.path.abspath(os.path.expanduser(str(path)))))

def normalized(path):
    path = str(path)
    if os.name == 'nt' and path.startswith('\\\\?\\UNC\\'):
        path = '\\\\' + path[8:]
    elif os.name == 'nt' and path.startswith('\\\\?\\'):
        path = path[4:]
    return os.path.normcase(os.path.abspath(path))

def native(path):
    """Extended Windows paths avoid MAX_PATH without changing stored/display paths."""
    path = str(path)
    if os.name != 'nt' or path.startswith('\\\\?\\'):
        return path
    path = os.path.abspath(path)
    return '\\\\?\\UNC\\' + path[2:] if path.startswith('\\\\') else '\\\\?\\' + path

def within(path, parent):
    try:
        return os.path.commonpath([canonical(path), canonical(parent)]) == canonical(parent)
    except (OSError, ValueError):
        return False

class Settings:
    def __init__(self, data):
        self.data = Path(data).resolve()
        self.data.mkdir(parents=True, exist_ok=True)
        self.file = self.data / 'settings.json'
        self.lock = threading.RLock()
        if not self.file.exists():
            self.save(DEFAULTS)

    def get(self):
        with self.lock:
            return DEFAULTS | json.loads(self.file.read_text('utf-8'))

    def validate(self, obj):
        result = DEFAULTS | {k: v for k, v in obj.items() if k in DEFAULTS}
        for key in ('roots', 'exclude_paths', 'exclude_names'):
            if not isinstance(result[key], list) or not all(isinstance(x, str) for x in result[key]):
                raise ValueError(f'{key}: expected a list of strings')
            result[key] = list(dict.fromkeys(x.strip() for x in result[key] if x.strip()))
        for name in ('roots', 'exclude_paths'):
            for path in result[name]:
                if not Path(path).expanduser().is_absolute():
                    raise ValueError(f'{name}: use absolute paths: {path}')
        if type(result['min_size']) is not int or result['min_size'] < 1:
            raise ValueError('min_size must be a positive integer')
        if type(result['system_exclusions']) is not bool:
            raise ValueError('system_exclusions must be a boolean')
        for key in ('ffprobe', 'ffmpeg'):
            if not isinstance(result[key], str):
                raise ValueError(f'{key}: expected executable path or empty string')
        return result

    def save(self, obj):
        result = self.validate(obj)
        with self.lock:
            fd, temporary = tempfile.mkstemp(dir=self.data, suffix='.tmp')
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                    json.dump(result, stream, ensure_ascii=False, indent=2)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.file)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        return result

class Scope:
    def __init__(self, settings, data):
        self.settings = settings
        self.roots = [canonical(p) for p in settings['roots']]
        self.excluded = [canonical(p) for p in settings['exclude_paths']] + [canonical(data)]
        if settings['system_exclusions']:
            if os.name == 'nt':
                self.excluded += [canonical(os.environ.get('SystemRoot', 'C:/Windows'))]
                self.excluded += [canonical(os.environ[k]) for k in ('ProgramFiles', 'ProgramFiles(x86)', 'ProgramData') if os.environ.get(k)]
            else:
                self.excluded += [canonical(p) for p in ('/proc', '/sys', '/dev', '/run')]
        self.names = {n.casefold() for n in settings['exclude_names']}

    def allowed(self, path):
        target = canonical(path)
        return self.contains(target)

    def contains(self, target):
        def under(parent):
            return target == parent or target.startswith(parent.rstrip(os.sep) + os.sep)
        return (any(under(r) for r in self.roots)
                and not any(under(x) for x in self.excluded)
                and not any(part.casefold() in self.names for part in target.split(os.sep)))

    def sql(self, column='path'):
        # All literals are quoted here; configuration never becomes SQL code.
        def quote(value):
            return "'" + value.replace("'", "''") + "'"
        def under(parent):
            prefix = parent.rstrip(os.sep) + os.sep
            return f'({column}={quote(parent)} OR ({column}>={quote(prefix)} AND {column}<{quote(prefix + chr(0x10ffff))}))'
        roots = '(' + ' OR '.join(under(r) for r in self.roots) + ')' if self.roots else '0'
        clauses = [roots] + ['NOT ' + under(p) for p in self.excluded]
        # Names are case-insensitive, with Unicode semantics matching the scanner.
        if self.names:
            names = '|'.join(sorted(self.names))
            # One cheap callback for names, avoiding filesystem/path resolution per row.
            clauses.append('allowed_names(' + column + ')')
        return ' AND '.join(clauses)

def is_link(stat):
    # Directory junctions and cloud placeholders must never be followed implicitly.
    return bool(getattr(stat, 'st_file_attributes', 0) & (0x400 | 0x1000 | 0x40000 | 0x400000))
