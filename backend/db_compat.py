"""Veltrix DB adapter. PostgreSQL in cloud, SQLite for local development.

Deliberately fail closed if DATABASE_URL is supplied but unavailable.
"""
import os
import re
import sqlite3
from pathlib import Path

PG_DSN = os.environ.get('DATABASE_URL', '').strip()

class PGConnection:
    def __init__(self, raw):
        self.raw = raw
    def execute(self, sql, params=None):
        sql = re.sub(r'\bINTEGER\s+PRIMARY\s+KEY\s+AUTOINCREMENT\b', 'BIGSERIAL PRIMARY KEY', sql, flags=re.I)
        sql = re.sub(r'\bBLOB\b', 'BYTEA', sql, flags=re.I)
        # Existing SQL queries use SQLite positional placeholders. No queries in the
        # uploaded files contain literal question marks inside SQL string constants.
        sql = sql.replace('?', '%s')
        return self.raw.execute(sql, params)
    def __enter__(self):
        self.raw.__enter__()
        return self
    def __exit__(self, typ, val, tb):
        return self.raw.__exit__(typ, val, tb)
    def commit(self):
        return self.raw.commit()
    def rollback(self):
        return self.raw.rollback()
    def close(self):
        return self.raw.close()

def connect(path=None, timeout=10):
    if PG_DSN:
        import psycopg
        from psycopg.rows import dict_row
        return PGConnection(psycopg.connect(PG_DSN, row_factory=dict_row, connect_timeout=timeout))
    path = path or str(Path(__file__).parent / 'veltrix_auth.db')
    conn = sqlite3.connect(str(path), timeout=timeout)
    conn.row_factory = sqlite3.Row
    return conn

IntegrityError = sqlite3.IntegrityError

def is_integrity_error(exc):
    if isinstance(exc, sqlite3.IntegrityError):
        return True
    if PG_DSN:
        from psycopg import IntegrityError as PGIntegrityError
        return isinstance(exc, PGIntegrityError)
    return False
