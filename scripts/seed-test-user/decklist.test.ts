import assert from 'node:assert/strict';
import { test } from 'node:test';

import { parseDecklist } from './decklist.ts';

test('reads quantities and names under TappedOut section headers', () => {
  const deck = parseDecklist(`Land (2)

    1x Command Tower
    2x Island

Commander (1)
Commander: The Ur-Dragon
`);
  assert.deepEqual(deck.commander, { name: 'The Ur-Dragon', finish: 'nonfoil' });
  assert.deepEqual(deck.cards, [
    { name: 'Command Tower', quantity: 1, finish: 'nonfoil' },
    { name: 'Island', quantity: 2, finish: 'nonfoil' },
  ]);
});

test('strips the foil, etched, Game Changer and Flip markers', () => {
  const deck = parseDecklist(`Commander: foil Jace, Multiverse Architect
    1x Ancient TombGC
    1x Blood Cryptfoil
    1x Mox DiamondfoilGC
    1x Avacyn, Angel of Hope *f-etch*
    1x Ojer Taq, Deepest Foundationfoil  Flip
    1x Sol Ring *f*
`);
  assert.deepEqual(deck.commander, { name: 'Jace, Multiverse Architect', finish: 'foil' });
  assert.deepEqual(deck.cards, [
    { name: 'Ancient Tomb', quantity: 1, finish: 'nonfoil' },
    { name: 'Blood Crypt', quantity: 1, finish: 'foil' },
    { name: 'Mox Diamond', quantity: 1, finish: 'foil' },
    { name: 'Avacyn, Angel of Hope', quantity: 1, finish: 'etched' },
    { name: 'Ojer Taq, Deepest Foundation', quantity: 1, finish: 'foil' },
    { name: 'Sol Ring', quantity: 1, finish: 'foil' },
  ]);
});

test('adds up repeated lines of the same card and finish', () => {
  const deck = parseDecklist(`Commander: The Ur-Dragon
    3x Forest
    1x Forest
    1x Forest
    1x Islandfoil
    1x Island
`);
  assert.deepEqual(deck.cards, [
    { name: 'Forest', quantity: 5, finish: 'nonfoil' },
    { name: 'Island', quantity: 1, finish: 'foil' },
    { name: 'Island', quantity: 1, finish: 'nonfoil' },
  ]);
});

test('reads plain lines without the x, and skips blanks and headers', () => {
  const deck = parseDecklist('Commander: The Ur-Dragon\n\nSorcery (2)\n1 Explore\n1x Farseek\n');
  assert.deepEqual(
    deck.cards.map((card) => card.name),
    ['Explore', 'Farseek'],
  );
});

test('fails without a commander, or on a line it cannot read', () => {
  assert.throws(() => parseDecklist('1x Sol Ring'), /no "Commander:" line/);
  assert.throws(() => parseDecklist('Commander: The Ur-Dragon\nSol Ring'), /line 2: "Sol Ring"/);
});
