import hashlib
import json
import math
import shutil
import subprocess
from fractions import Fraction
from pathlib import Path

try:
    from PIL import Image, ImageOps
except ImportError:
    Image = ImageOps = None

VERSION = 'metadata-v1'

def executable(settings, key):
    return settings.get(key) or shutil.which(key)

def capabilities(settings):
    return {'pillow': Image is not None,
            'ffprobe': bool(executable(settings, 'ffprobe')),
            'ffmpeg': bool(executable(settings, 'ffmpeg')),
            'face_recognition': False, 'semantic_search': False,
            'object_detection': False, 'video_similarity': False}

def shape(width, height):
    if not width or not height:
        return {}
    gcd = math.gcd(width, height)
    # Common capture ratios are useful even after a few pixels of cropping.
    ratio = width / height
    common = [(1, 1), (4, 3), (3, 4), (3, 2), (2, 3), (16, 9), (9, 16), (21, 9)]
    nearest = min(common, key=lambda pair: abs(ratio - pair[0] / pair[1]))
    aspect = f'{nearest[0]}:{nearest[1]}' if abs(ratio - nearest[0] / nearest[1]) / ratio < .025 else f'{width//gcd}:{height//gcd}'
    return {'width': width, 'height': height, 'aspect': aspect,
            'orientation': 'square' if width == height else 'landscape' if width > height else 'portrait'}

def dhash(image):
    gray = image.convert('L').resize((9, 8))
    px = list(gray.tobytes())
    bits = 0
    for y in range(8):
        for x in range(8):
            bits = (bits << 1) | (px[y * 9 + x] > px[y * 9 + x + 1])
    return f'{bits:016x}'

def probe(path, kind, settings):
    if kind == 'image':
        if Image is None:
            return {'unavailable': 'Pillow is not installed'}
        with Image.open(path) as original:
            result = {'format': original.format, 'frames': getattr(original, 'n_frames', 1)}
            exif = original.getexif()
            for tag, name in ((36867, 'captured'), (271, 'make'), (272, 'camera'), (42036, 'lens')):
                value = exif.get(tag)
                if value is None and tag == 36867:
                    value = exif.get_ifd(34665).get(tag)
                if value is not None:
                    result[name] = str(value).strip('\x00 ')
            image = ImageOps.exif_transpose(original)
            result.update(shape(*image.size))
            image.thumbnail((512, 512))
            result['dhash'] = dhash(image)
            return result
    binary = executable(settings, 'ffprobe')
    if not binary:
        return {'unavailable': 'ffprobe is not configured'}
    process = subprocess.run([binary, '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(path)],
                             capture_output=True, timeout=40, check=True,
                             creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    raw = json.loads(process.stdout)
    stream = next((s for s in raw.get('streams', []) if s.get('codec_type') == 'video' and not s.get('disposition', {}).get('attached_pic')), {})
    width, height = stream.get('width', 0), stream.get('height', 0)
    rotations = [x.get('rotation', 0) for x in stream.get('side_data_list', [])]
    rotation = float(stream.get('tags', {}).get('rotate', rotations[0] if rotations else 0))
    if abs(rotation) % 180 == 90:
        width, height = height, width
    result = shape(width, height)
    result.update(codec=stream.get('codec_name'), format=raw.get('format', {}).get('format_name'),
                  duration=float(raw.get('format', {}).get('duration', 0)),
                  bitrate=int(raw.get('format', {}).get('bit_rate', 0)),
                  captured=stream.get('tags', {}).get('creation_time', raw.get('format', {}).get('tags', {}).get('creation_time')))
    try:
        result['fps'] = round(float(Fraction(stream.get('avg_frame_rate', '0'))), 3)
    except (ValueError, ZeroDivisionError):
        pass
    return result

def thumbnail(path, kind, settings, destination):
    if kind == 'image' and Image:
        with Image.open(path) as original:
            image = ImageOps.exif_transpose(original)
            image.thumbnail((480, 320))
            image.convert('RGB').save(destination, 'JPEG', quality=80)
        return True
    binary = executable(settings, 'ffmpeg')
    if kind == 'video' and binary:
        subprocess.run([binary, '-nostdin', '-v', 'error', '-i', str(path), '-frames:v', '1',
                        '-vf', 'scale=480:320:force_original_aspect_ratio=decrease', '-y', str(destination)],
                       capture_output=True, timeout=25, check=True,
                       creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        return True
    return False

def cache_key(row):
    return hashlib.sha256(f"{row['path']}|{row['size']}|{row['mtime_ns']}|{row['ctime_ns']}|{row['dev']}|{row['ino']}|{VERSION}".encode()).hexdigest()
