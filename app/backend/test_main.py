from unittest.mock import MagicMock, patch
from fastapi.testclient import TestClient
import main
client = TestClient(main.app)
def test_health():
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok"}
def test_list_todos():
    mock_conn = MagicMock()
    mock_cur = mock_conn.cursor.return_value.__enter__.return_value
    mock_cur.fetchall.return_value = [{"id": 1, "title": "Learn EKS", "done": 0}]
    with patch("main.get_conn", return_value=mock_conn):
        res = client.get("/api/todos")
    assert res.status_code == 200
    assert res.json() == [{"id": 1, "title": "Learn EKS", "done": False}]
def test_create_todo_rejects_empty():
    res = client.post("/api/todos", json={"title": "   "})
    assert res.status_code == 400
def test_create_todo_success():
    mock_conn = MagicMock()
    mock_cur = mock_conn.cursor.return_value.__enter__.return_value
    mock_cur.lastrowid = 42
    with patch("main.get_conn", return_value=mock_conn):
        res = client.post("/api/todos", json={"title": "Deploy ArgoCD"})
    assert res.status_code == 201
    assert res.json() == {"id": 42, "title": "Deploy ArgoCD", "done": False}
