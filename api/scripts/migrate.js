import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import pool from '../db.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function migrate() {
  try {
    const migrationFile = path.join(__dirname, '../migrations/001_initial_schema.sql');
    const sql = fs.readFileSync(migrationFile, 'utf8');
    
    await pool.query(sql);
    console.log('Migration completed successfully');
    process.exit(0);
  } catch (error) {
    console.error('Migration failed:', error);
    process.exit(1);
  }
}

migrate();

