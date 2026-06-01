import Database from 'better-sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const dbPath = process.env.SQLITE_PATH || path.join(__dirname, '..', '..', '..', 'database.sqlite');

let db;
function getDb() {
  if (!db) {
    db = new Database(dbPath);
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
    console.log(`SQLite connected: ${dbPath}`);
  }
  return db;
}

async function query(sql, params = []) {
  const database = getDb();
  const isSelect = sql.trim().toUpperCase().startsWith('SELECT');
  try {
    if (isSelect) return database.prepare(sql).all(...params);
    else return database.prepare(sql).run(...params);
  } catch (err) {
    console.error('SQLite error:', err.message);
    throw err;
  }
}

async function getConnection() {
  const database = getDb();
  return {
    query: async (s, p) => query(s, p),
    execute: async (s, p) => query(s, p),
    release: () => {},
    beginTransaction: () => { database.prepare('BEGIN').run(); },
    commit: () => { database.prepare('COMMIT').run(); },
    rollback: () => { database.prepare('ROLLBACK').run(); },
  };
}

async function executeQuery(sql, params = []) { return query(sql, params); }

async function executeTransaction(queries) {
  const database = getDb();
  const t = database.transaction(() => {
    const results = [];
    for (const { query: q, params = [] } of queries) {
      results.push(database.prepare(q).all(...params));
    }
    return results;
  });
  return t();
}

async function testConnection() {
  const database = getDb();
  const result = database.prepare('SELECT 1 as ok').get();
  console.log('Database connection OK:', result);
  return true;
}

export { getDb, getConnection, executeQuery, executeTransaction, testConnection, query };