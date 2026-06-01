const Database = require('./backend/node_modules/better-sqlite3');
const bcrypt = require('./backend/node_modules/bcryptjs');

const db = new Database('./database.sqlite');

// Generate new hash for "admin123"
const newPassword = 'admin123';
const hash = bcrypt.hashSync(newPassword, 12);

db.prepare('UPDATE users SET password = ? WHERE username = ?').run(hash, 'admin');
console.log(`Password for "admin" reset to: ${newPassword}`);
console.log(`New hash: ${hash}`);

// Verify
const user = db.prepare('SELECT * FROM users WHERE username = ?').get('admin');
console.log('User:', user);

db.close();
