import Database from 'better-sqlite3';
const SQLITE_PATH = process.env.SQLITE_PATH ?? './feed.db';

if (!SQLITE_PATH) throw new Error('SQLITE_PATH is not defined');

export const db = new Database(SQLITE_PATH, {
    fileMustExist: true,
});

db.pragma('journal_mode = WAL');
db.pragma('synchronous = NORMAL');
db.pragma('temp_store = MEMORY');
db.pragma('cache_size = -65536');
db.pragma('mmap_size = 1073741824');

export const healthStmt = db.prepare(`
    SELECT 1
`);


export default db;
