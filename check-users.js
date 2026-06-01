const Database = require('./backend/node_modules/better-sqlite3');
const db = new Database('./database.sqlite');

// List all tables
const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all();
console.log('Tables:', tables.map(t => t.name));

// Check users table
try {
  const users = db.prepare('SELECT * FROM users').all();
  console.log('\nUsers:', JSON.stringify(users, null, 2));
} catch(e) {
  console.log('Users table error:', e.message);
}

// Check admins table
try {
  const admins = db.prepare('SELECT * FROM admins').all();
  console.log('\nAdmins:', JSON.stringify(admins, null, 2));
} catch(e) {
  console.log('Admins table error:', e.message);
}

db.close();
