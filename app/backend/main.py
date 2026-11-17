import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import pymysql
from pymysql.cursors import DictCursor

app = FastAPI(title="Todo API")
_table_ready = False


def get_conn(use_db=True):
    kwargs = dict(
        host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", "3306")),
        user=os.getenv("DB_USER", "todouser"),
        password=os.getenv("DB_PASSWORD", "todopass"),
        cursorclass=DictCursor,
        autocommit=True,
    )
    if use_db:
        kwargs["database"] = os.getenv("DB_NAME", "tododb")
    return pymysql.connect(**kwargs)


def ensure_table():
    global _table_ready
    if _table_ready:
        return
    db_name = os.getenv("DB_NAME", "tododb").replace("`", "")
    conn = get_conn(use_db=False)
    try:
        with conn.cursor() as cur:
            cur.execute(f"CREATE DATABASE IF NOT EXISTS `{db_name}`")
            cur.execute(f"USE `{db_name}`")
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS todos (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    title VARCHAR(255) NOT NULL,
                    done BOOLEAN NOT NULL DEFAULT FALSE
                )
                """
            )
        _table_ready = True
    finally:
        conn.close()


class TodoCreate(BaseModel):
    title: str


class TodoUpdate(BaseModel):
    done: bool


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/api/todos")
def list_todos():
    ensure_table()
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id, title, done FROM todos ORDER BY id DESC")
            rows = cur.fetchall()
            for r in rows:
                r["done"] = bool(r["done"])
            return rows
    finally:
        conn.close()


@app.post("/api/todos", status_code=201)
def create_todo(todo: TodoCreate):
    title = todo.title.strip()
    if not title:
        raise HTTPException(status_code=400, detail="Title cannot be empty")
    ensure_table()
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute("INSERT INTO todos (title, done) VALUES (%s, %s)", (title, False))
            todo_id = cur.lastrowid
        return {"id": todo_id, "title": title, "done": False}
    finally:
        conn.close()


@app.patch("/api/todos/{todo_id}")
def toggle_todo(todo_id: int, payload: TodoUpdate):
    ensure_table()
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute("UPDATE todos SET done = %s WHERE id = %s", (payload.done, todo_id))
            if cur.rowcount == 0:
                raise HTTPException(status_code=404, detail="Todo not found")
            cur.execute("SELECT id, title, done FROM todos WHERE id = %s", (todo_id,))
            row = cur.fetchone()
            row["done"] = bool(row["done"])
            return row
    finally:
        conn.close()


@app.delete("/api/todos/{todo_id}")
def delete_todo(todo_id: int):
    ensure_table()
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM todos WHERE id = %s", (todo_id,))
            if cur.rowcount == 0:
                raise HTTPException(status_code=404, detail="Todo not found")
        return {"deleted": todo_id}
    finally:
        conn.close()
