'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadLib } = require('./load-lib');

const Theme = loadLib('Theme.js');

const SAMPLE_TOML = [
  '# a comment, must be ignored',
  'red = "#e06c75"',
  'yellow = "#e5c07b"',
  'green = "#98c379"',
  'cyan = "#56b6c2"',
  'not_a_color = 5',
  'bright_black = "#5c6370"',
].join('\n');

test('parseColorsToml extracts quoted hex colors and ignores everything else', () => {
  const palette = Theme.parseColorsToml(SAMPLE_TOML);
  assert.equal(palette.red, '#e06c75');
  assert.equal(palette.yellow, '#e5c07b');
  assert.equal(palette.green, '#98c379');
  assert.equal(palette.not_a_color, undefined);
});

test('parseColorsToml on empty/missing text returns an empty object', () => {
  assert.deepEqual(Theme.parseColorsToml(''), {});
  assert.deepEqual(Theme.parseColorsToml(null), {});
});

const BASE = {
  foreground: '#ffffff',
  background: '#000000',
  accent: '#61afef',
  urgent: '#e06c75',
  muted: '#5c6370',
  popupsBackground: '#101010',
  popupsText: '#eeeeee',
  popupsBorder: '#333333',
};

test('tokenColor resolves warn/crit from the raw palette', () => {
  const palette = Theme.parseColorsToml(SAMPLE_TOML);
  assert.equal(Theme.tokenColor('warn', palette, BASE), '#e5c07b');
  assert.equal(Theme.tokenColor('crit', palette, BASE), '#e06c75');
});

test('tokenColor falls back to Color.foreground when the palette lacks a key', () => {
  assert.equal(Theme.tokenColor('warn', {}, BASE), BASE.foreground);
});

test('tokenColor resolves base tokens without needing the palette', () => {
  assert.equal(Theme.tokenColor('fg', {}, BASE), BASE.popupsText);
  assert.equal(Theme.tokenColor('accent', {}, BASE), BASE.accent);
});

test('contrast matches the WCAG reference pairs', () => {
  assert.equal(Theme.contrast('#000000', '#ffffff'), 21);
  assert.equal(Theme.contrast('#ffffff', '#ffffff'), 1);
  assert.ok(Math.abs(Theme.contrast('#777777', '#ffffff') - 4.48) < 0.01);
  // Order doesn't matter, and Qt's #aarrggbb / object forms parse the same.
  assert.equal(Theme.contrast('#ffffff', '#000000'), 21);
  assert.equal(Theme.contrast('#ff000000', '#ffffffff'), 21);
  assert.equal(Theme.contrast({ r: 0, g: 0, b: 0 }, '#fff'), 21);
  assert.equal(Theme.contrast('nope', '#fff'), 1);
});

test('mix blends by weight and returns lower-case hex', () => {
  assert.equal(Theme.mix('#000000', '#ffffff', 1), '#000000');
  assert.equal(Theme.mix('#000000', '#ffffff', 0), '#ffffff');
  assert.equal(Theme.mix('#000000', '#ffffff', 0.5), '#808080');
  assert.equal(Theme.mix('#AABBCC', '#AABBCC', 0.3), '#aabbcc');
});

test('mutedFor keeps at least 4:1 against the ground on dark and light themes', () => {
  const pairs = [
    ['#a9b1d6', '#1a1b26'],   // tokyo-night
    ['#4c4f69', '#eff1f5'],   // catppuccin-latte
    ['#d4be98', '#282828'],   // gruvbox
    ['#eeeeee', '#101010'],
  ];
  for (const [fg, bg] of pairs) {
    const dim = Theme.mutedFor(fg, bg);
    assert.ok(Theme.contrast(dim, bg) >= 4, `${fg} on ${bg} -> ${dim}`);
    // ...but is still visibly quieter than the foreground itself.
    assert.ok(Theme.contrast(dim, bg) < Theme.contrast(fg, bg), `${fg} on ${bg} -> ${dim}`);
  }
});

test('legibleOn keeps a tone that already reads on its tint and darkens one that does not', () => {
  // tokyo-night: green on a 14% green wash over the dark ground already clears 4:1.
  assert.equal(Theme.legibleOn('#9ece6a', 0.14, '#1a1b26', '#a9b1d6'), '#9ece6a');
  // catppuccin-latte: the same construction sits near 2.6:1, so the tone is pulled
  // toward the (dark) foreground until it clears the floor, and no further.
  const latte = Theme.legibleOn('#40a02b', 0.14, '#eff1f5', '#4c4f69');
  const wash = Theme.mix('#40a02b', '#eff1f5', 0.14);
  assert.notEqual(latte, '#40a02b');
  assert.ok(Theme.contrast(latte, wash) >= 4, latte);
  assert.ok(Theme.contrast(Theme.mix('#40a02b', '#4c4f69', 0.9), wash) < 4 || latte === Theme.mix('#40a02b', '#4c4f69', 0.9));
  // Unparsable input passes through; a missing foreground returns the tone.
  assert.equal(Theme.legibleOn('nope', 0.2, '#000000', '#ffffff'), 'nope');
  assert.equal(Theme.legibleOn('#ff0000', 0.2, '#ffffff', null), '#ff0000');
});

test('mutedFor honours a custom floor and degrades to the foreground when it cannot be met', () => {
  assert.equal(Theme.mutedFor('#777777', '#ffffff', 4.4), '#777777');
  assert.equal(Theme.mutedFor('#888888', '#808080'), '#888888');
  assert.equal(Theme.mutedFor('garbage', '#000000'), 'garbage');
});

test('tokenColor dim is derived from the popup text/ground pair, not the theme muted key', () => {
  const dim = Theme.tokenColor('dim', {}, BASE);
  assert.notEqual(dim, BASE.muted);
  assert.equal(dim, Theme.mutedFor(BASE.popupsText, BASE.popupsBackground));
});

test('tokenColor crit falls back to Color.urgent when the palette has no red', () => {
  assert.equal(Theme.tokenColor('crit', {}, BASE), BASE.urgent);
});
