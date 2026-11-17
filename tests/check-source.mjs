import { readFile } from 'node:fs/promises';
import { Script } from 'node:vm';
import assert from 'node:assert/strict';

// Static integration checks only. These do not compile Swift or emulate an iPhone.
export async function checkSources() {
  const base = new URL('../', import.meta.url);
  const read = path => readFile(new URL(path, base), 'utf8');
  const [html, js, frontend, library, bridge, player, plist, workflow] = await Promise.all([
    'Web/index.html', 'Web/native.js', 'Frontend/native-app.js', 'Native/NativeLibrary.swift',
    'Native/MiMediaApp.swift', 'Native/NativePlayer.swift', 'Native/Info.plist', '.github/workflows/build-ipa.yml'
  ].map(read));
  new Script(js);
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
  for (const [, id] of frontend.matchAll(/\$\('([^']+)'\)/g)) {
    if (id === 'edit-') continue; // The four metadata fields are selected dynamically.
    assert(ids.has(id), `Falta elemento HTML: ${id}`);
  }
  for (const field of ['title', 'artist', 'album', 'year']) assert(ids.has('edit-' + field));
  for (const [, method] of frontend.matchAll(/invoke\('([^']+)'/g)) {
    assert((library + bridge).includes('"' + method + '"'), `Falta comando Swift: ${method}`);
  }
  assert(!/serviceWorker|indexedDB|\bfetch\s*\(|<script\b[^>]*https?:|rel="manifest"/.test(html + js));
  for (const [, asset] of html.matchAll(/(?:src|href)="\.\/([^"]+)"/g)) await readFile(new URL('Web/' + asset, base));
  assert(plist.includes('<string>audio</string>'));
  assert(player.includes('setCategory(.playback'));
  assert(player.includes('MPRemoteCommandCenter'));
  assert(bridge.includes('loadFileURL'));
  assert(bridge.includes('message.frameInfo.isMainFrame'));
  assert(library.includes('URLSession.shared.download'));
  assert(library.includes('args["authorized"] as? Bool == true'));
  assert(library.includes('AudioLinks.youtube.contains'));
  assert(workflow.includes('workflow_dispatch:') && !workflow.includes('push:'));
  assert((await read('scripts/build-unsigned.sh')).includes('CODE_SIGNING_ALLOWED=NO'));
  const wav = await readFile(new URL('Native/prueba-mimedia.wav', base));
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wav.toString('ascii', 8, 12), 'WAVE');
  const png = await readFile(new URL('Native/Assets.xcassets/AppIcon.appiconset/AppIcon.png', base));
  assert.equal(png.readUInt32BE(16), 1024); assert.equal(png.readUInt32BE(20), 1024);
  return { result: 'PASS', htmlIDs: ids.size, nativeSyntax: 'NO COMPILADA: requiere Xcode', device: 'NO PROBADO' };
}

// Optional direct execution: node -e "import('./tests/check-source.mjs').then(async m=>console.log(await m.checkSources()))"
