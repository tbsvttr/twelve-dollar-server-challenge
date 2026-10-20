// Deterministic seed data: users.tsv, posts.tsv, likes.tsv and tokens.json in the given directory.
// No dependencies (Node >= 18). Run it through make-seed.sh, which also builds feed.db from the TSVs.
//
//   node seed/generate.mjs <out-dir>
//
// Everything comes from one PRNG (mulberry32, seed 42), so every run produces byte-identical files:
// 50,000 users, 500,000 posts, ~2,000,000 likes. Do not change this file; the golden test files
// depend on its exact output.
import { createWriteStream, mkdirSync, writeFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';

const OUT = process.argv[2];
if (!OUT) { console.error('usage: node generate.mjs <out-dir>'); process.exit(1); }
const SEED = 42, USERS = 50_000, POSTS = 500_000, LIKES = 2_000_000;
const JWT_SECRET = process.env.JWT_SECRET ?? 'twelve-dollar-challenge';
const TOKEN_COUNT = 20_000;

const END = Date.parse('2026-01-01T00:00:00Z');
const DAY = 86_400_000;

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = mulberry32(SEED);
const randInt = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
const pick = (arr) => arr[Math.floor(rand() * arr.length)];
const expo = (mean) => -mean * Math.log(1 - rand());

const ADJECTIVES = ['quiet', 'brave', 'clever', 'sunny', 'rusty', 'swift', 'lazy', 'mellow', 'sharp', 'wild', 'cosmic', 'tiny', 'golden', 'silver', 'happy', 'grumpy', 'curious', 'lucky', 'salty', 'zesty'];
const NOUNS = ['otter', 'falcon', 'badger', 'comet', 'river', 'maple', 'pixel', 'walrus', 'ember', 'glacier', 'lantern', 'meadow', 'nebula', 'orchid', 'pebble', 'quartz', 'raven', 'sparrow', 'thistle', 'willow'];
const WORDS = (
  'the a an and but or so because while after before just really very kind of sort of maybe probably definitely ' +
  'server database request latency cache index query benchmark droplet cpu memory disk network throughput users ' +
  'coffee morning weekend project deploy release bug feature test rewrite refactor commit branch merge review ' +
  'thinking building shipping learning reading writing debugging measuring watching waiting running walking ' +
  'fast slow small big cheap simple boring clever weird surprising honest careful lucky tired ready done broken ' +
  'today tonight tomorrow yesterday again finally never always sometimes usually rarely once twice ' +
  'this that these those here there everywhere nowhere something nothing everything anything someone ' +
  'nginx node postgres typescript express linux ubuntu systemd load steal swap kernel socket keepalive pool'
).split(/\s+/);
const OPENERS = ['Hot take:', 'TIL', 'Unpopular opinion:', 'Note to self:', 'PSA:', 'Okay so', 'Update:', 'Honestly,', 'Reminder:', 'Question:'];

function sentence() {
  const n = randInt(4, 14);
  const words = [];
  for (let i = 0; i < n; i++) words.push(pick(WORDS));
  const s = words.join(' ');
  return s.charAt(0).toUpperCase() + s.slice(1) + pick(['.', '.', '.', '!', '?', '...']);
}
function postBody() {
  const parts = [];
  if (rand() < 0.25) parts.push(pick(OPENERS));
  const sentences = randInt(1, 3);
  for (let i = 0; i < sentences; i++) parts.push(sentence());
  let body = parts.join(' ');
  if (body.length > 500) body = body.slice(0, 497) + '...';
  return body;
}
const ts = (ms) => new Date(ms).toISOString();

async function writeRows(name, total, rowFn) {
  const stream = createWriteStream(`${OUT}/${name}.tsv`);
  const done = new Promise((resolve, reject) => { stream.on('finish', resolve); stream.on('error', reject); });
  let buf = [];
  for (let i = 0; i < total; i++) {
    buf.push(rowFn(i));
    if (buf.length === 2_000 || i === total - 1) {
      if (!stream.write(buf.join('\n') + '\n')) await new Promise((res) => stream.once('drain', res));
      buf = [];
    }
  }
  stream.end();
  await done;
  console.log(`  ${name}.tsv: ${total.toLocaleString()} rows`);
}

mkdirSync(OUT, { recursive: true });

const usernames = [];
await writeRows('users', USERS, (i) => {
  const id = i + 1;
  const username = `${pick(ADJECTIVES)}_${pick(NOUNS)}_${id}`;
  usernames.push(username);
  return `${id}\t${username}\t${ts(END - 730 * DAY + rand() * 365 * DAY)}`;
});

// Posts are spread evenly over 2025 in id order (small jitter); authorship is skewed toward low user ids.
const postStart = END - 365 * DAY;
const step = (365 * DAY) / POSTS;
const postCreatedAt = new Float64Array(POSTS);
await writeRows('posts', POSTS, (i) => {
  const userId = 1 + Math.floor(USERS * rand() * rand());
  const createdAt = postStart + i * step + rand() * step * 0.9;
  postCreatedAt[i] = createdAt;
  return `${i + 1}\t${userId}\t${postBody()}\t${ts(createdAt)}`;
});

// Likes per post: exponential around the mean, 1% "popular" posts at ~20x. Distinct users per post.
const meanPerPost = LIKES / POSTS;
const popularMean = meanPerPost * 20;
const normalMean = Math.max(0.05, (meanPerPost - 0.01 * popularMean + 0.5) / 0.99);
const cap = Math.min(USERS, Math.max(50, Math.round(popularMean * 10)));
let likeTotal = 0;
const perPost = new Array(POSTS);
for (let i = 0; i < POSTS; i++) {
  perPost[i] = Math.min(cap, Math.floor(expo(rand() < 0.01 ? popularMean : normalMean)));
  likeTotal += perPost[i];
}
let postIdx = 0, remaining = 0;
const seen = new Set();
await writeRows('likes', likeTotal, () => {
  while (remaining === 0) { postIdx++; remaining = perPost[postIdx - 1]; seen.clear(); }
  remaining--;
  let userId;
  do userId = randInt(1, USERS); while (seen.has(userId));
  seen.add(userId);
  return `${userId}\t${postIdx}\t${ts(postCreatedAt[postIdx - 1] + rand() * 7 * DAY)}`;
});

// Pre-signed HS256 tokens for the first TOKEN_COUNT users (for bench/load.js). Valid for 10 years.
const b64url = (s) => Buffer.from(s).toString('base64url');
const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
const iat = Math.floor(Date.now() / 1000);
const tokens = usernames.slice(0, TOKEN_COUNT).map((username, i) => {
  const payload = b64url(JSON.stringify({ sub: String(i + 1), username, iat, exp: iat + 3650 * 86400 }));
  const sig = createHmac('sha256', JWT_SECRET).update(`${header}.${payload}`).digest('base64url');
  return { id: i + 1, username, token: `${header}.${payload}.${sig}` };
});
writeFileSync(`${OUT}/tokens.json`, JSON.stringify(tokens));
console.log(`  tokens.json: ${tokens.length.toLocaleString()} tokens (JWT_SECRET=${JWT_SECRET})`);
