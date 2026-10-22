import db from './db.js';

export const healthStmt = db.prepare(`
SELECT 1
`);

export default healthStmt;