'use strict';
const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const titles = {catalog: ['Вся медиатека. Одно место.', 'Находите нужное, сравнивайте копии и исследуйте свою коллекцию.'], duplicates: ['Одинаковое содержимое.', 'Копии на разных дисках, подтверждённые полным хэшем файла.'], similar: ['Похожи. Но не всегда одинаковы.', 'Сравнивайте версии снимков и выбирайте лучший экземпляр.'], labels: ['Связи внутри коллекции.', 'Люди, места, объекты и события — ваши способы находить нужное.'], analysis: ['Больше, чем имя файла.', 'Свойства, визуальные признаки и состояние фоновой обработки.'], settings: ['Ваша коллекция. Ваши правила.', 'Выберите источники и папки, которые нужно пропустить.']};
const categories = {person: 'Люди', place: 'Места', object: 'Объекты', event: 'События', tag: 'Метки'};
let token = '', tab = 'catalog', page = 0, dupOffset = 0, catalogData, selectedFile, settings, lastJobVersion = '', toastTimer;
let catalogRequest = 0, lastCatalogRefresh = 0, lastCatalogCount = -1;
let capabilities = {};
function el(tag, cls, text) { const node = document.createElement(tag); if (cls) node.className = cls; if (text !== undefined) node.textContent = text; return node; }
function bytes(value) { if (!value) return '0 Б'; const unit = Math.min(4, Math.floor(Math.log(value) / Math.log(1024))); return `${(value / 1024 ** unit).toLocaleString('ru', {maximumFractionDigits: unit ? 1 : 0})} ${['Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ'][unit]}`; }
function notify(message) { $('#toast').textContent = message; $('#toast').hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 12000); }
async function api(path, body) { const response = await fetch(path, body === undefined ? {} : {method: 'POST', headers: {'Content-Type': 'application/json', 'X-SmartClean-Token': token}, body: JSON.stringify(body)}); const data = await response.json(); if (!response.ok) throw new Error(data.error || response.statusText); return data; }
function run(fn) { return (...args) => Promise.resolve().then(() => fn(...args)).catch(e => notify(e.message)); }
function empty(container, message) { container.replaceChildren(el('div', 'error-empty', message)); }
async function navigate(name) {
 tab = name; $$('.view').forEach(v => { v.hidden = v.id !== name; }); $$('[data-tab]').forEach(b => b.classList.toggle('active', b.dataset.tab === name));
 $('#title').textContent = titles[name][0]; $('#subtitle').textContent = titles[name][1]; $('#breadcrumb').textContent = $(`[data-tab="${name}"]`).textContent.trim();
 if (name === 'catalog') await loadCatalog();
 if (name === 'duplicates') await loadDuplicates();
 if (name === 'labels') await loadLabels();
 if (name === 'analysis') await refreshStatus();
 if (name === 'settings') await loadSettings();
}
function imageFor(file, cls) { if (file.kind === 'video' && !capabilities.ffmpeg || file.kind === 'image' && (!capabilities.pillow || !['.jpg','.jpeg','.png','.webp','.gif','.bmp','.tif','.tiff','.avif'].includes(file.ext))) return el('span', cls, cls ? 'Превью для этого формата пока недоступно' : ''); const image = el('img', cls); image.alt = file.path.split(/[\\/]/).pop(); image.loading = 'lazy'; image.src = `/api/preview/${file.id}`; image.addEventListener('error', () => image.remove(), {once: true}); return image; }
function card(file) {
 const button = el('button', 'card'); button.type = 'button'; button.title = file.path;
 const thumb = el('div', 'thumb', file.kind === 'video' ? '▷' : '▧'); thumb.append(imageFor(file), el('span', 'file-badge', file.ext.slice(1).toUpperCase()));
 const body = el('div', 'card-body'); body.append(el('div', 'card-name', file.path.split(/[\\/]/).pop()));
 const meta = el('div', 'card-meta'); const m = file.metadata || {}; meta.append(el('span', '', bytes(file.size)), el('span', '', m.width ? `${m.width} × ${m.height}` : file.kind === 'video' ? 'Видео' : 'Фото')); body.append(meta, el('div', 'card-path', file.path)); button.append(thumb, body); button.addEventListener('click', run(() => showDetail(file))); return button;
}
async function loadCatalog() {
 const request = ++catalogRequest;
 const query = new URLSearchParams({page, q: $('#search').value, kind: $('#kind').value, ext: $('#extension').value, aspect: $('#aspect').value, sort: $('#sort').value});
 const data = await api('/api/catalog?' + query); if (request !== catalogRequest) return; catalogData = data; lastCatalogRefresh = Date.now(); lastCatalogCount = data.total;
 $('#file-count').textContent = data.total.toLocaleString('ru'); $('#grid').replaceChildren(...data.files.map(card)); $('#catalog-empty').hidden = data.total !== 0;
 if (!data.total) { $('#catalog-empty h2').textContent = settings?.roots.length ? 'Файлы пока не найдены' : 'Начнём с ваших папок'; }
 $('#prev').disabled = page === 0; $('#next').disabled = (page + 1) * data.limit >= data.total; $('#page-label').textContent = data.total ? `${page + 1} / ${Math.ceil(data.total / data.limit)}` : '';
 const selected = $('#extension').value; $('#extension').replaceChildren(new Option('Все форматы', ''), ...data.extensions.map(x => new Option(x.slice(1).toUpperCase(), x))); $('#extension').value = selected;
}
async function loadDuplicates() {
 const data = await api(`/api/duplicates?offset=${dupOffset}`); const list = $('#duplicate-list'); list.replaceChildren();
 for (const group of data.groups) { const section = el('article', 'group'); section.append(el('h3', '', `${group.files.length} экземпляра · ${bytes(group.size)} каждый · повторное содержимое ${bytes(group.duplicate_logical_bytes)}${group.has_hardlinks ? ' · есть жёсткие ссылки' : ''}`)); const grid = el('div', 'grid'); grid.append(...group.files.map(card)); section.append(grid); list.append(section); }
 if (!data.groups.length) empty(list, 'Подтверждённых дублей пока нет. Запустите сканирование выбранных источников.');
 list.append(el('p', 'muted', data.note)); $('#dup-prev').disabled = dupOffset === 0; $('#dup-next').disabled = dupOffset + 30 >= data.total; $('#dup-page').textContent = `${data.total} групп`;
}
async function loadSimilar() {
 $('#find-similar').disabled = true;
 try { const data = await api('/api/similar?threshold=' + $('#threshold').value); const list = $('#similar-list'); list.replaceChildren();
 for (const pair of data.pairs) { const section = el('article', 'group'); section.append(el('h3', '', `Различие визуальных отпечатков: ${pair.distance} / 64`)); const grid = el('div', 'grid'); grid.append(...pair.files.map(card)); section.append(grid); list.append(section); }
 if (!data.pairs.length) empty(list, 'Похожие фото пока не найдены. Для сравнения сначала выполните анализ.');
 $('#similar-note').textContent = `Проверено фото: ${data.processed} из ${data.total}. ${data.limited ? 'Показана ограниченная выборка: до 20 000 фото и 300 пар. Для большой коллекции нужен следующий модуль индекса.' : ''} Используется dHash; возможны ложные совпадения, особенно у однотонных изображений.`;
 } finally { $('#find-similar').disabled = false; }
}
async function loadLabels() { const labels = await api('/api/labels'); const list = $('#label-list'); list.replaceChildren(); for (const [category, title] of Object.entries(categories)) { const group = el('article', 'label-group'); group.append(el('h3', '', title)); const items = labels.filter(l => l.category === category); if (!items.length) group.append(el('p', 'muted', 'Назначьте метку в карточке файла')); for (const label of items) { const chip = el('button', 'chip', `${label.value} · ${label.count}`); chip.addEventListener('click', run(async () => { $('#search').value = label.value; page = 0; await navigate('catalog'); })); group.append(chip); } list.append(group); } }
async function loadSettings() {
 settings = await api('/api/settings'); $('#roots').value = settings.roots.join('\n'); $('#exclusions').value = settings.exclude_paths.join('\n'); $('#exclude-names').value = settings.exclude_names.join('\n'); $('#system-exclusions').checked = settings.system_exclusions; $('#min-size').value = settings.min_size; $('#ffprobe').value = settings.ffprobe; $('#ffmpeg').value = settings.ffmpeg;
 const volumes = await api('/api/volumes'); $('#volumes').replaceChildren(); for (const volume of volumes) { const row = el('div', 'volume'); row.append(el('strong', '', volume.path), el('small', '', `${bytes(volume.free)} свободно из ${bytes(volume.total)}`)); const add = el('button', '', '+'); add.type = 'button'; add.title = 'Добавить диск в источники'; add.addEventListener('click', () => { const roots = lines($('#roots').value); if (!roots.includes(volume.path)) roots.push(volume.path); $('#roots').value = roots.join('\n'); }); row.append(add); $('#volumes').append(row); }
}
function lines(value) { return value.split('\n').map(s => s.trim()).filter(Boolean); }
async function saveSettings(event) { event.preventDefault(); settings = await api('/api/settings', {...settings, roots: lines($('#roots').value), exclude_paths: lines($('#exclusions').value), exclude_names: lines($('#exclude-names').value), system_exclusions: $('#system-exclusions').checked, min_size: Number($('#min-size').value), ffprobe: $('#ffprobe').value.trim(), ffmpeg: $('#ffmpeg').value.trim()}); notify('Настройки сохранены. Запустите сканирование, когда источники готовы.'); await refreshStatus(); }
async function start(kind) { settings = await api('/api/settings'); if (!settings.roots.length) { await navigate('settings'); notify('Добавьте папки или диски и сохраните настройки.'); return; } await api('/api/jobs', {kind}); await refreshStatus(); }
async function refreshStatus() {
 const status = await api('/api/status'); capabilities = status.capabilities; for (const key of ['files', 'images', 'videos']) $(`#stat-${key}`).textContent = status.totals[key].toLocaleString('ru'); $('#stat-bytes').textContent = bytes(status.totals.bytes);
 const job = status.job || status.recent[0]; $('#job-panel').hidden = !job; const active = job && ['running', 'cancelling'].includes(job.state); $('#scan').disabled = !!active; $('#analyze').disabled = !!active;
 $('#resume').hidden = !status.resume_available;
 if (job) { const phase = {inventory: 'Обход папок', hashing: 'Сравнение содержимого', metadata: 'Свойства и отпечатки', done: 'Задача завершена', interrupted: 'Прервана при закрытии приложения'}; const state = {completed: 'Завершено', running: 'В работе', cancelling: 'Остановка…', cancelled: 'Остановлено', failed: 'Ошибка', interrupted: 'Можно запустить повторно'}; $('#job-name').textContent = phase[job.phase] || job.phase; $('#job-state').textContent = state[job.state] || job.state; const s = job.stats; $('#job-counters').textContent = `Найдено: ${s.discovered} · Из кэша: ${s.cached} · Полных хэшей: ${s.full_hashed} · Проанализировано: ${s.analyzed} · Ошибок: ${s.errors}`; $('#job-path').textContent = s.current || job.error || 'Результаты сохранены в локальном индексе'; $('#cancel').hidden = !active; $('#cancel').disabled = job.state === 'cancelling'; const version = job.id + job.state; if (lastJobVersion && version !== lastJobVersion && job.state === 'completed' && tab === 'catalog') await loadCatalog(); lastJobVersion = version; }
 if (job) {
  const seconds = Math.max(0, (job.finished || Date.now()/1000) - job.started), s = job.stats;
  const elapsed = `${Math.floor(seconds/60)} мин ${Math.floor(seconds%60)} с`;
  const average = seconds > 0 ? Math.round(s.discovered / seconds).toLocaleString('ru') : '0';
  $('#job-explanation').textContent = {inventory:'Этап 1 из 2: составляем список фото и видео. Содержимое файлов ещё не сравнивается. Найденные файлы уже доступны в каталоге. Общий объём работы станет известен после обхода.',hashing:'Этап 2 из 2: сравниваем содержимое кандидатов в дубли. Крупные файлы могут читаться долго. Метаданные и распознавание запускаются отдельной задачей.',metadata:'Читаем свойства медиа и создаём отпечатки фото. Это отдельный этап после инвентаризации.',done:'Результаты сохранены. Размер коллекции — суммарный размер файлов, а не объём прочитанных данных.'}[job.phase] || 'Задачу можно продолжить повторным запуском; сохранённые результаты используются из кэша.';
  $('#job-timing').textContent = `Прошло: ${elapsed} · Средняя скорость: ${average} медиа/с · Папок: ${(s.folders||0).toLocaleString('ru')} · Источников завершено: ${s.sources_done||0}/${s.sources_total||settings?.roots.length||0}${active && s.updated && Date.now()/1000-s.updated>20 ? ' · Нет новых записей более 20 с: ожидается ответ диска' : ''}`;
  $('#job-errors').hidden = !s.errors;
  if (s.saved_full_hashes) $('#job-counters').textContent += ` · Полных хэшей сохранено до продолжения: ${s.saved_full_hashes.toLocaleString('ru')}`;
  $('#job-errors').textContent = `Показать ошибки (${s.errors||0})`;
 }
 if (active && tab === 'catalog' && status.totals.files !== lastCatalogCount && Date.now()-lastCatalogRefresh > 10000) await loadCatalog();
 if (tab === 'analysis') { renderCapabilities(status.capabilities); $('#history').replaceChildren(...status.recent.map(j => { const row = el('div', 'history-row'); row.append(el('span', '', j.kind === 'scan' ? 'Индекс и точные дубли' : 'Анализ медиа'), el('span', '', j.state), el('span', '', new Date(j.started * 1000).toLocaleString('ru'))); return row; })); $('#errors').replaceChildren(...status.errors.map(e => el('div', 'error-row', `${e.path}: ${e.message}`))); if (!status.errors.length) empty($('#errors'), 'Ошибок нет'); }
}
function renderCapabilities(c) {
 const features = [ ['Свойства фото', c.pillow, 'Размер, пропорции, ориентация, камера, дата съёмки, визуальный отпечаток.'], ['Свойства видео', c.ffprobe, 'Длительность, кодек, разрешение, FPS, битрейт. Нужен ffprobe.'], ['Превью видео', c.ffmpeg, 'Первый кадр по запросу, с сохранением в кэш. Нужен ffmpeg.'], ['Люди и группы лиц', false, 'В плане: обнаружение лиц, объединение по сходству, имена и ручное исправление групп.'], ['Места и объекты', false, 'В плане: GPS и карта, визуальные сцены, объекты и подтверждение предположений.'], ['Поиск по смыслу', false, 'В плане: локальные эмбеддинги фото и кадров, запросы словами, OCR и текст видео.'], ['Похожие видео', false, 'В плане: последовательности кадров, пережатые копии, фрагменты и таймкоды совпадений.'], ['Контролируемая очистка', false, 'В плане: выбор сохраняемой копии, повторная проверка, карантин и журнал отката.'], ['Фоновый индекс', true, 'Возобновление повторным запуском, кэш хэшей, исключения и учёт жёстких ссылок.'] ];
 $('#capabilities').replaceChildren(...features.map(([title, ready, description]) => { const block = el('article', 'feature'); block.append(el('span', `badge${ready ? '' : ' pending'}`, ready ? 'Доступно' : title.includes('видео') && ['Свойства видео', 'Превью видео'].includes(title) ? 'Нужен инструмент' : 'Следующий этап'), el('h3', '', title), el('p', '', description)); return block; }));
}
async function showDetail(file) { selectedFile = file; const content = $('#detail-content'); content.replaceChildren(); content.append(imageFor(file, 'detail-preview'), el('p', 'detail-path', file.path)); const fields = { 'Размер': bytes(file.size), 'Тип': file.ext.toUpperCase(), 'Изменён': new Date(file.mtime_ns / 1e6).toLocaleString('ru'), 'SHA-256': file.digest || 'Не вычислялся: нет кандидатов или задача ещё не выполнена', 'Жёстких ссылок': file.nlink }; const names = {width:'Ширина',height:'Высота',aspect:'Пропорции',orientation:'Ориентация',captured:'Дата съёмки',make:'Производитель',camera:'Камера',lens:'Объектив',duration:'Длительность, с',codec:'Кодек',fps:'Кадров/с',bitrate:'Битрейт',format:'Формат',frames:'Кадров изображения',unavailable:'Анализ недоступен'}; for (const [key, value] of Object.entries(file.metadata || {})) if (names[key] && value !== null) fields[names[key]] = value; const table = el('table', 'metadata-table'); for (const [key, value] of Object.entries(fields)) { const tr = el('tr'); tr.append(el('td', '', key), el('td', '', String(value))); table.append(tr); } content.append(table); const chips = el('div'); for (const label of file.labels || []) { const chip = el('button', 'chip', `${categories[label.category]}: ${label.value} ×`); chip.title = 'Удалить метку'; chip.addEventListener('click', run(async () => { await api('/api/labels', {file_id:file.id, ...label, remove:true}); file.labels = file.labels.filter(l => l !== label); await showDetail(file); })); chips.append(chip); } content.append(chips); if (!$('#detail').open) $('#detail').showModal(); }
$$('[data-tab]').forEach(button => button.addEventListener('click', run(() => navigate(button.dataset.tab))));
$('#add-sources').addEventListener('click', run(() => navigate('settings')));
$('#scan').addEventListener('click', run(() => start('scan'))); $('#analyze').addEventListener('click', run(() => start('analyze')));
$('#resume').addEventListener('click', run(() => start('resume')));
$('#cancel').addEventListener('click', run(async () => { await api('/api/jobs/cancel', {}); await refreshStatus(); }));
$('#job-errors').addEventListener('click', run(async () => { await navigate('analysis'); $('.errors').open = true; $('.errors').scrollIntoView({block:'center'}); }));
$('#settings-form').addEventListener('submit', run(saveSettings));
$('#refresh').addEventListener('click', run(async () => { await refreshStatus(); await navigate(tab); }));
for (const id of ['kind', 'extension', 'aspect', 'sort']) $('#' + id).addEventListener('change', run(async () => { page = 0; await loadCatalog(); }));
let searchTimer; $('#search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(run(async () => { page = 0; await loadCatalog(); }), 300); });
$('#prev').addEventListener('click', run(async () => { page = Math.max(0, page - 1); await loadCatalog(); })); $('#next').addEventListener('click', run(async () => { page++; await loadCatalog(); }));
$('#dup-prev').addEventListener('click', run(async () => { dupOffset = Math.max(0, dupOffset - 30); await loadDuplicates(); })); $('#dup-next').addEventListener('click', run(async () => { dupOffset += 30; await loadDuplicates(); }));
$('#find-similar').addEventListener('click', run(loadSimilar)); $('#close-detail').addEventListener('click', () => $('#detail').close());
$('#label-form').addEventListener('submit', run(async event => { event.preventDefault(); const category = $('#label-category').value, value = $('#label-value').value.trim(); if (!value) return; await api('/api/labels', {file_id:selectedFile.id, category, value}); selectedFile.labels ||= []; if (!selectedFile.labels.some(l => l.category === category && l.value === value)) selectedFile.labels.push({category,value}); $('#label-value').value = ''; await showDetail(selectedFile); }));
async function poll() { try { await refreshStatus(); } catch(e) { notify(`Связь с приложением: ${e.message}`); } finally { setTimeout(poll, 2500); } }
run(async () => { token = (await api('/api/session')).token; settings = await api('/api/settings'); await refreshStatus(); await navigate('catalog'); setTimeout(poll, 2500); })();
