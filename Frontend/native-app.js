/* Classic local script. Download, catalog and playback calls go to native Swift, never to a website. */
const pendingNative = new Map();
let nativeSequence = 0, state = { songs: [], jobs: [], playlists: [], shuffled: false, repeatMode: 'off' };
let view = 'songs', groupKey = null, limit = 100, searchLimit = 100, editingID = null;
const $ = id => document.getElementById(id);
function notice(message) { $('status').textContent = message; }
function failed(error) { notice(error.message || String(error)); }
function invoke(method, args = {}) {
  return new Promise((resolve, reject) => {
    if (!window.webkit?.messageHandlers?.mimedia) { reject(new Error('El puente nativo no está disponible. Esta interfaz se abre dentro de la aplicación iOS.')); return; }
    const id = String(++nativeSequence);
    const timeout = setTimeout(() => { pendingNative.delete(id); reject(new Error('La operación nativa no respondió.')); }, 30000);
    pendingNative.set(id, { resolve, reject, timeout });
    window.webkit.messageHandlers.mimedia.postMessage({ id, method, args: JSON.parse(JSON.stringify(args)) });
  });
}
window.MiMediaNative = { receive(message) {
  if (message.event === 'playback') { state = { ...state, ...message.value }; renderPlayer(); return; }
  if (message.event === 'state') { applyState(message.value); return; }
  const pending = pendingNative.get(message.id);
  if (!pending) return;
  clearTimeout(pending.timeout); pendingNative.delete(message.id);
  if (message.error) pending.reject(new Error(message.error));
  else { applyState(message.value); pending.resolve(message.value); }
} };
function node(tag, className, text) {
  const value = document.createElement(tag); if (className) value.className = className;
  if (text !== undefined) value.textContent = text; return value;
}
function action(text, callback, className = 'small-button') {
  const button = node('button', className, text); button.type = 'button';
  button.addEventListener('click', () => Promise.resolve().then(callback).catch(failed)); return button;
}
function empty(title, text) { const box = node('div', 'empty'); box.append(node('strong', '', title), document.createTextNode(text)); return box; }
function art(song, className = 'art') {
  const box = node('span', className, '♪'); box.setAttribute('aria-hidden', 'true');
  if (song?.artwork) { const image = node('img'); image.src = song.artwork; image.alt = ''; box.replaceChildren(image); } return box;
}
function route() {
  const page = ['inicio', 'buscar', 'biblioteca', 'playlists'].includes(location.hash.slice(1)) ? location.hash.slice(1) : 'inicio';
  document.querySelectorAll('.page').forEach(pageNode => { pageNode.hidden = pageNode.id !== page; });
  document.querySelectorAll('[data-page]').forEach(link => { if (link.dataset.page === page) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current'); });
}
window.addEventListener('hashchange', route); route();
const jobNames = { queued: 'En cola', downloading: 'Descargando', verifying: 'Verificando', completed: 'Guardada en el iPhone', failed: 'No descargada', cancelled: 'Cancelada', interrupted: 'Interrumpida', unsupported: 'Fuente pendiente', removed: 'Archivo eliminado' };
function renderJobs() {
  $('downloads').replaceChildren();
  const pending = state.jobs.filter(job => ['queued', 'downloading', 'verifying'].includes(job.state)).length;
  $('queue-count').textContent = pending ? `${pending} en cola / proceso` : 'Sin pendientes';
  if (!state.jobs.length) $('downloads').append(empty('Todo empieza con un enlace', 'Las descargas se guardan como archivos privados de MiMedia.'));
  for (const job of [...state.jobs].reverse().slice(0, 50)) {
    const row = node('article', 'job'); row.dataset.state = job.state;
    row.append(node('strong', '', job.title), node('p', '', `${jobNames[job.state] || job.state}${job.detail ? ' · ' + job.detail : ''}`));
    if (job.state === 'downloading') {
      const progress = node('progress'); progress.setAttribute('aria-label', 'Progreso de descarga');
      if (typeof job.progress === 'number') { progress.max = 1; progress.value = job.progress; }
      row.append(progress);
    }
    if (['queued', 'downloading', 'verifying'].includes(job.state)) row.append(action('Cancelar', () => invoke('cancel', { id: job.id })));
    if (['failed', 'cancelled', 'interrupted', 'removed'].includes(job.state)) row.append(action('Reintentar', () => invoke('retry', { id: job.id, authorized: $('authorized').checked })));
    $('downloads').append(row);
  }
}
function row(song, tracks) {
  const container = node('article', 'song'), copy = node('div', 'song-copy');
  container.append(art(song));
  copy.append(action(song.title, () => invoke('play', { id: song.id, queue: tracks.map(item => item.id) }), 'song-title'));
  copy.append(node('small', '', `${song.artist || 'Artista desconocido'}${song.album ? ' · ' + song.album : ''}`), node('small', 'offline-badge', `↓ ARCHIVO LOCAL · ${formatDuration(song.duration)} · ${formatBytes(song.size)}`));
  const details = node('details'); details.append(node('summary', '', 'Opciones'));
  const actions = node('div', 'actions');
  actions.append(action('Editar detalles y carátula', () => edit(song)), action('Compartir archivo', () => invoke('share', { id: song.id })), action('Eliminar audio', async () => { if (confirm(`¿Eliminar «${song.title}» de MiMedia y sus playlists?`)) await invoke('deleteSong', { id: song.id }); }));
  details.append(actions); copy.append(details); container.append(copy);
  const favorite = action(song.favorite ? '♥' : '♡', () => invoke('favorite', { id: song.id }), 'icon-button favorite-button');
  favorite.setAttribute('aria-label', `${song.favorite ? 'Quitar de' : 'Añadir a'} favoritos: ${song.title}`); favorite.setAttribute('aria-pressed', String(song.favorite)); container.append(favorite);
  return container;
}
function libraryTracks() {
  if (view === 'favorites') return state.songs.filter(song => song.favorite);
  if (groupKey) return groupSongs(state.songs, view).find(group => group.key === groupKey)?.songs || [];
  return state.songs;
}
function renderLibrary() {
  const tracks = libraryTracks(), root = $('library'); root.replaceChildren();
  $('home-count').textContent = state.songs.length; $('home-favorite-count').textContent = state.songs.filter(song => song.favorite).length;
  $('library-count').textContent = `${state.songs.length} canciones · ${formatBytes(state.songs.reduce((sum, song) => sum + song.size, 0))}`;
  document.querySelectorAll('[data-library]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.library === view)));
  $('group-heading').hidden = !groupKey;
  const grouped = ['albums', 'artists'].includes(view) && !groupKey;
  $('play-all').disabled = !tracks.length || grouped;
  if (grouped) {
    const grid = node('div', 'collection-grid');
    for (const group of groupSongs(state.songs, view).slice(0, limit)) {
      const card = action('', () => { groupKey = group.key; $('group-title').textContent = group.title; limit = 100; renderLibrary(); }, 'collection-card');
      card.append(art(group.songs.find(song => song.artwork) || group.songs[0], 'collection-cover'), node('strong', '', group.title), node('small', '', `${group.subtitle} · ${group.songs.length} canciones`)); grid.append(card);
    }
    root.append(grid);
  } else {
    root.append(...tracks.slice(0, limit).map(song => row(song, tracks)));
    if (tracks.length > limit) root.append(action('Cargar más', () => { limit += 100; renderLibrary(); }, 'secondary'));
  }
  if (!state.songs.length) root.append(empty('Tu biblioteca está por sonar', 'Pega un enlace de audio autorizado en Inicio.'));
  else if (!tracks.length) root.append(empty('Sin canciones', 'Marca el corazón para añadir favoritos.'));
}
function renderSearch() {
  const tracks = searchSongs(state.songs, $('search').value);
  $('search-results').replaceChildren(...tracks.slice(0, searchLimit).map(song => row(song, tracks)));
  if (tracks.length > searchLimit) $('search-results').append(action('Cargar más', () => { searchLimit += 100; renderSearch(); }, 'secondary'));
  if (!tracks.length) $('search-results').append(empty('Sin coincidencias', 'Busca entre título, artista y álbum de tu música guardada.'));
}
function renderPlaylists() {
  $('playlist-list').replaceChildren();
  if (!state.playlists.length) $('playlist-list').append(empty('Una lista para cada momento', 'Crea una playlist con tu música local.'));
  for (const playlist of state.playlists) {
    const tracks = playlist.songIDs.map(id => state.songs.find(song => song.id === id)).filter(Boolean);
    const card = node('article', 'playlist-card'); card.append(node('h2', '', playlist.name), node('small', 'muted', `${tracks.length} canciones`));
    const actions = node('div', 'playlist-actions');
    const play = action('▶ Reproducir', () => invoke('play', { id: tracks[0].id, queue: tracks.map(song => song.id) })); play.disabled = !tracks.length;
    actions.append(play, action('Renombrar', async () => { const name = prompt('Nombre de la playlist', playlist.name)?.trim(); if (name) await invoke('playlist.rename', { id: playlist.id, name }); }), action('Eliminar', async () => { if (confirm(`¿Eliminar «${playlist.name}» conservando sus canciones?`)) await invoke('playlist.delete', { id: playlist.id }); })); card.append(actions);
    const select = node('select'); select.setAttribute('aria-label', `Añadir canción a ${playlist.name}`);
    const placeholder = node('option', '', 'Añadir canción…'); placeholder.value = ''; select.append(placeholder);
    for (const song of state.songs.filter(song => !playlist.songIDs.includes(song.id))) { const option = node('option', '', song.title); option.value = song.id; select.append(option); }
    select.addEventListener('change', () => { if (select.value) invoke('playlist.songs', { id: playlist.id, songIDs: [...playlist.songIDs, select.value] }).catch(failed); }); card.append(select);
    for (const song of tracks) {
      const track = node('div', 'playlist-track'); track.append(art(song, 'cover-mini'), action(song.title, () => invoke('play', { id: song.id, queue: tracks.map(item => item.id) }), 'song-title'));
      for (const [label, offset] of [['↑', -1], ['↓', 1]]) track.append(action(label, () => invoke('playlist.songs', { id: playlist.id, songIDs: moveSongIDs(playlist.songIDs, song.id, offset) })));
      track.append(action('Quitar', () => invoke('playlist.songs', { id: playlist.id, songIDs: playlist.songIDs.filter(id => id !== song.id) }))); card.append(track);
    }
    $('playlist-list').append(card);
  }
}
function renderPlayer() {
  const song = state.songs.find(song => song.id === state.currentID);
  $('now-title').textContent = song?.title || 'Tu música, a tu ritmo';
  $('now-subtitle').textContent = song ? [song.artist || 'Artista desconocido', 'Reproductor nativo'].join(' · ') : 'Elige una canción de tu biblioteca';
  const picture = art(song, 'cover-mini'); picture.id = 'now-art'; $('now-art').replaceWith(picture);
  $('native-toggle').textContent = state.playing ? 'Pausar' : 'Reproducir'; $('native-toggle').disabled = !song;
  $('native-seek').disabled = !song; $('native-seek').max = state.duration || 1;
  if (document.activeElement !== $('native-seek')) $('native-seek').value = state.position || 0;
  $('native-time').textContent = `${formatDuration(state.position)} / ${formatDuration(state.duration)}`;
  $('now-favorite').disabled = !song; $('now-favorite').textContent = song?.favorite ? '♥' : '♡'; $('now-favorite').setAttribute('aria-pressed', String(!!song?.favorite));
  $('shuffle').setAttribute('aria-pressed', String(state.shuffled)); $('repeat').setAttribute('aria-pressed', String(state.repeatMode !== 'off')); $('repeat').textContent = `Repetir: ${{ off: 'no', one: 'una', all: 'todo' }[state.repeatMode]}`;
}
let lastCatalog = '';
function applyState(next) {
  state = next;
  const signature = JSON.stringify([state.songs, state.playlists, state.jobs]);
  if (signature !== lastCatalog) { lastCatalog = signature; renderLibrary(); renderSearch(); renderPlaylists(); renderJobs(); }
  renderPlayer(); if (state.loadError) notice(state.loadError);
}
function edit(song) {
  editingID = song.id;
  for (const field of ['title', 'artist', 'album', 'year']) $('edit-' + field).value = song[field] || '';
  $('edit-artwork').value = ''; $('remove-artwork').checked = false; $('editor-status').textContent = ''; $('edit-song').showModal();
}
async function blobDataURL(blob) { return new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.onerror = reject; reader.readAsDataURL(blob); }); }
$('metadata-form').addEventListener('submit', async event => {
  event.preventDefault(); $('save-metadata').disabled = true;
  try {
    const patch = checkedMetadata(Object.fromEntries(['title', 'artist', 'album', 'year'].map(field => [field, $('edit-' + field).value])));
    const file = $('edit-artwork').files[0];
    const artwork = file ? await blobDataURL(await prepareArtwork(file)) : undefined;
    await invoke('edit', { id: editingID, ...patch, artwork, removeArtwork: $('remove-artwork').checked }); $('edit-song').close();
  } catch (error) { $('editor-status').textContent = error.message; }
  finally { $('save-metadata').disabled = false; }
});
$('close-editor').addEventListener('click', () => $('edit-song').close());
$('download-form').addEventListener('submit', async event => {
  event.preventDefault(); $('download-button').disabled = true;
  try { await invoke('enqueue', { text: $('links').value, authorized: $('authorized').checked }); $('links').value = ''; $('authorized').checked = false; notice('Enlaces registrados. Consulta el estado de cada descarga.'); }
  catch (error) { failed(error); } finally { $('download-button').disabled = false; }
});
$('links').addEventListener('input', () => { $('authorized').checked = false; });
$('continue-queue').addEventListener('click', () => invoke('continue').catch(failed));
$('cancel-all').addEventListener('click', async () => { for (const job of state.jobs.filter(job => ['queued', 'downloading', 'verifying'].includes(job.state))) { try { await invoke('cancel', { id: job.id }); } catch (error) { failed(error); } } });
$('playlist-form').addEventListener('submit', async event => { event.preventDefault(); try { await invoke('playlist.create', { name: $('playlist-name').value }); $('playlist-name').value = ''; } catch (error) { failed(error); } });
$('search').addEventListener('input', () => { searchLimit = 100; renderSearch(); });
document.querySelectorAll('[data-library]').forEach(button => button.addEventListener('click', () => { view = button.dataset.library; groupKey = null; limit = 100; renderLibrary(); }));
$('back-groups').addEventListener('click', () => { groupKey = null; renderLibrary(); });
$('home-favorites').addEventListener('click', () => { view = 'favorites'; groupKey = null; renderLibrary(); location.hash = 'biblioteca'; });
$('play-all').addEventListener('click', () => { const tracks = libraryTracks(); if (tracks.length) invoke('play', { id: tracks[0].id, queue: tracks.map(song => song.id) }).catch(failed); });
$('now-favorite').addEventListener('click', () => invoke('favorite', { id: state.currentID }).catch(failed));
$('native-toggle').addEventListener('click', () => invoke(state.playing ? 'pause' : 'resume').catch(failed));
$('native-seek').addEventListener('change', () => invoke('seek', { seconds: Number($('native-seek').value) }).catch(failed));
$('next').addEventListener('click', () => invoke('next').catch(failed)); $('previous').addEventListener('click', () => invoke('previous').catch(failed));
$('shuffle').addEventListener('click', () => invoke('preferences', { shuffled: !state.shuffled }).catch(failed));
$('repeat').addEventListener('click', () => invoke('preferences', { repeatMode: { off: 'all', all: 'one', one: 'off' }[state.repeatMode] }).catch(failed));
$('help-button').addEventListener('click', () => $('help').showModal()); $('close-help').addEventListener('click', () => $('help').close());
$('native-test').addEventListener('click', async () => { try { await invoke('addTestAudio'); $('help').close(); location.hash = 'biblioteca'; notice('Tono integrado guardado localmente. Esta prueba no realiza una descarga de Internet.'); } catch (error) { failed(error); } });
$('connection').textContent = 'App iOS · local';
$('storage-info').textContent = 'Audio y catálogo guardados en el espacio privado de MiMedia. No hay sincronización automática con Android ni con la PWA.';
$('persist').hidden = true;
if ('ResizeObserver' in window) new ResizeObserver(entries => document.documentElement.style.setProperty('--dock-height', `${entries[0].target.getBoundingClientRect().height}px`)).observe(document.querySelector('.bottom-bar'));
invoke('state').catch(failed);
