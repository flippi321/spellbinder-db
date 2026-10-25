// Reads a decklist as TappedOut shows it, pasted as is: section headers (`Land (30)`), `1x Name` lines, and a
// `Commander: Name` line. TappedOut glues markers onto names: `foil` and `*f*` (foil), `*f-etch*` (etched),
// `GC` (Game Changer) and `  Flip` (double-faced); they are stripped, and the first two become the finish.

export type Finish = 'nonfoil' | 'foil' | 'etched';

export interface DeckLine {
  name: string;
  quantity: number;
  finish: Finish;
}

export interface Decklist {
  commander: { name: string; finish: Finish };
  /** Without the commander. A card in two finishes is two lines. */
  cards: DeckLine[];
}

const HEADER = /^[A-Za-z ]+ \(\d+\)$/;
const CARD = /^(\d+)x?\s+(.+)$/;
const COMMANDER = /^Commander:\s*(.+)$/;

const MARKERS: { pattern: RegExp; finish?: Finish }[] = [
  { pattern: /\s*\*f-etch\*$/, finish: 'etched' },
  { pattern: /\s*\*f\*$/, finish: 'foil' },
  { pattern: /(?<=\S)foil$/, finish: 'foil' },
  { pattern: /^foil\s+/, finish: 'foil' },
  { pattern: /(?<=\S)GC$/ },
  { pattern: /\s+Flip$/ },
];

/** Strips TappedOut's markers off a name, in any order (`Mox DiamondfoilGC`). */
function cleanName(raw: string): { name: string; finish: Finish } {
  let name = raw.trim();
  let finish: Finish = 'nonfoil';
  for (let stripped = true; stripped; ) {
    stripped = false;
    for (const marker of MARKERS) {
      if (!marker.pattern.test(name)) continue;
      name = name.replace(marker.pattern, '').trim();
      if (marker.finish && finish === 'nonfoil') finish = marker.finish;
      stripped = true;
    }
  }
  return { name, finish };
}

export function parseDecklist(text: string): Decklist {
  let commander: Decklist['commander'] | null = null;
  const cards: DeckLine[] = [];
  text.split(/\r?\n/).forEach((raw, index) => {
    const line = raw.trim();
    if (line === '' || HEADER.test(line)) return;
    const commanderMatch = COMMANDER.exec(line);
    if (commanderMatch) {
      commander = cleanName(commanderMatch[1]);
      return;
    }
    const cardMatch = CARD.exec(line);
    if (!cardMatch) throw new Error(`Can't read line ${index + 1}: "${line}"`);
    const { name, finish } = cleanName(cardMatch[2]);
    const quantity = Number(cardMatch[1]);
    const same = cards.find((card) => card.name === name && card.finish === finish);
    if (same) same.quantity += quantity;
    else cards.push({ name, quantity, finish });
  });
  if (!commander) throw new Error('The decklist has no "Commander:" line.');
  return { commander, cards };
}
