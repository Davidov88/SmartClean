"""Windows application-window launcher; scan service survives closing the window."""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen


def healthy(url):
    try:
        with urlopen(url + '/api/health', timeout=2) as response:
            return json.load(response).get('app') == 'SmartClean'
    except (OSError, ValueError, URLError):
        return False


def browser_executable():
    for base in ('PROGRAMFILES(X86)', 'PROGRAMFILES', 'LOCALAPPDATA'):
        if not os.environ.get(base):
            continue
        for relative in ('Microsoft/Edge/Application/msedge.exe', 'Google/Chrome/Application/chrome.exe'):
            path = Path(os.environ[base]) / relative
            if path.is_file():
                return path
    raise RuntimeError('Для окна SmartClean установите Microsoft Edge или Google Chrome.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data-dir', default=os.environ.get('SMARTCLEAN_DATA_DIR', '.local'))
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    data = Path(args.data_dir).resolve()
    data.mkdir(parents=True, exist_ok=True)
    try:
        if os.name != 'nt':
            raise RuntimeError('Отдельное окно в этой версии доступно на Windows. Сервер: python -m smartclean')
        browser = browser_executable()
        url = f'http://127.0.0.1:{args.port}'
        if not healthy(url):
            python = Path(sys.executable).with_name('pythonw.exe')
            helper = Path(__file__).resolve().parents[1] / 'tools' / 'start-service.ps1'
            result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(helper),
                                     '-PythonExe', str(python), '-DataDir', str(data), '-Port', str(args.port)],
                                    capture_output=True, timeout=45, creationflags=subprocess.CREATE_NO_WINDOW)
            if result.returncode:
                raise RuntimeError('Не удалось запустить независимый сервис: ' + result.stderr.decode(errors='replace'))
            deadline = time.monotonic() + 60
            while not healthy(url):
                if time.monotonic() > deadline:
                    raise RuntimeError('Запуск занимает больше минуты. Проверьте server-error.log.')
                time.sleep(.25)
        # Both the worker and window are launched by Windows, outside the caller's job.
        python = Path(sys.executable).with_name('pythonw.exe')
        helper = Path(__file__).resolve().parents[1] / 'tools' / 'start-service.ps1'
        result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(helper),
                                 '-PythonExe', str(python), '-DataDir', str(data), '-Port', str(args.port), '-BrowserExe', str(browser)],
                                capture_output=True, timeout=45, creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode:
            raise RuntimeError('Не удалось открыть окно SmartClean: ' + result.stderr.decode(errors='replace'))
    except Exception as exc:
        (data / 'desktop-error.log').write_text(str(exc), encoding='utf-8')
        if os.name == 'nt':
            import ctypes
            ctypes.windll.user32.MessageBoxW(0, str(exc), 'SmartClean', 0x10)
        else:
            raise

if __name__ == '__main__':
    main()
