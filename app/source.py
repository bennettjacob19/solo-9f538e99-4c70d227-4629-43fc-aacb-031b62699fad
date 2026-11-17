"""源 PostgreSQL 访问：固定结构的增/改/删、快照基线、复制槽推进。

所有写接口都只操作 artifacts 表的四列固定结构，不接受任意 SQL。
"""
from __future__ import annotations

from contextlib import contextmanager
from typing import Any, Iterator

import psycopg2
import psycopg2.extras

from .config import Settings

FIXED_COLUMNS = ("artifact_no", "service_name", "version", "sha256")


class SourceError(Exception):
    pass


class OperationIdConflict(SourceError):
    """网页操作号已存在（同一操作号重复提交），整组回滚、不产生第二个事务。"""

    def __init__(self, operation_id: str) -> None:
        super().__init__(f"操作号已存在，拒绝重复提交: {operation_id}")
        self.operation_id = operation_id


class SourceDB:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    @contextmanager
    def connect(self) -> Iterator[psycopg2.extensions.connection]:
        conn = psycopg2.connect(self._settings.pg_dsn)
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def ensure_schema(self) -> None:
        """幂等建表 + 空表播种（固定结构，无 DDL 变更通道）。"""
        import os

        sql_path = os.path.join(
            os.path.dirname(os.path.dirname(__file__)), "init", "01_schema.sql"
        )
        with self.connect() as conn, conn.cursor() as cur:
            with open(sql_path, "r", encoding="utf-8") as fh:
                cur.execute(fh.read())

    # ------------------------------------------------------------- 业务写入
    def apply_operations(
        self,
        operations: list[dict[str, Any]],
        operation_id: str | None = None,
    ) -> dict[str, Any]:
        """成组修改源目录：全部操作在同一个源事务里，要么全成功要么全回滚。

        若给定网页操作号 operation_id，则在**同一事务**内把
        (operation_id, 当前事务 xid) 写入来源登记表：来源与目录修改同成败，
        回滚时登记一并消失。主键冲突（同一操作号重复提交）直接报错，整组回滚。
        """
        inserted = updated = deleted = 0
        with self.connect() as conn, conn.cursor() as cur:
            if operation_id is not None:
                # txid_current()（PG 14/15/16 均内置）返回当前事务号；
                # 与随后的目录修改严格同事务，提交前对其他会话不可见。
                try:
                    cur.execute(
                        f"INSERT INTO {self._settings.origin_table}"
                        "(operation_id, xid) VALUES (%s, txid_current())",
                        (operation_id,),
                    )
                except psycopg2.errors.UniqueViolation:
                    # 操作号主键冲突：连接上下文管理器会回滚整个事务，
                    # 不产生任何目录修改，也不留第二条来源。
                    raise OperationIdConflict(operation_id)
            for op in operations:
                kind = op["op"]
                if kind == "insert":
                    cur.execute(
                        "INSERT INTO artifacts(artifact_no, service_name, version,"
                        " sha256) VALUES (%s, %s, %s, %s)",
                        (
                            op["artifact_no"],
                            op["service_name"],
                            op["version"],
                            op["sha256"],
                        ),
                    )
                    inserted += 1
                elif kind == "update":
                    cur.execute(
                        "UPDATE artifacts SET service_name=%s, version=%s,"
                        " sha256=%s WHERE artifact_no=%s",
                        (
                            op["service_name"],
                            op["version"],
                            op["sha256"],
                            op["artifact_no"],
                        ),
                    )
                    if cur.rowcount == 0:
                        raise SourceError(
                            f"UPDATE 失败：artifact_no={op['artifact_no']} 不存在"
                        )
                    updated += 1
                elif kind == "delete":
                    cur.execute(
                        "DELETE FROM artifacts WHERE artifact_no=%s",
                        (op["artifact_no"],),
                    )
                    if cur.rowcount == 0:
                        raise SourceError(
                            f"DELETE 失败：artifact_no={op['artifact_no']} 不存在"
                        )
                    deleted += 1
                else:  # pydantic 已拦截，这里只是防御
                    raise SourceError(f"不支持的操作类型: {kind}")
        return {"inserted": inserted, "updated": updated, "deleted": deleted}

    def list_artifacts(self) -> list[dict[str, Any]]:
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT artifact_no, service_name, version, sha256"
                " FROM artifacts ORDER BY artifact_no"
            )
            return [dict(zip(FIXED_COLUMNS, row)) for row in cur.fetchall()]

    def get_origin(self, operation_id: str) -> dict[str, Any] | None:
        """在源库查网页操作号的来源登记。

        只有已提交事务的登记对本查询可见：未提交/已回滚的事务其登记
        不可见或已随回滚消失，天然满足"回滚不留下可查来源"。
        返回 {"operation_id", "xid", "created_at"} 或 None。
        """
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute(
                f"SELECT operation_id, xid, created_at"
                f" FROM {self._settings.origin_table} WHERE operation_id=%s",
                (operation_id,),
            )
            row = cur.fetchone()
            if row is None:
                return None
            return {
                "operation_id": row[0],
                "xid": int(row[1]),
                "created_at": row[2].isoformat() if row[2] else None,
            }

    # ------------------------------------------------------------- 复制槽
    def slot_exists(self, slot_name: str) -> bool:
        with self.connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT 1 FROM pg_replication_slots WHERE slot_name=%s",
                (slot_name,),
            )
            return cur.fetchone() is not None

    def create_slot_with_snapshot(
        self, slot_name: str
    ) -> tuple[str, psycopg2.extensions.connection, str]:
        """创建逻辑复制槽并返回 (consistent_point LSN, 持有快照的连接, snapshot_id)。

        在一条普通连接的事务里先建槽（拿到槽的一致性 LSN），再
        pg_export_snapshot() 导出同一时刻快照；事务在基线读取完成前保持
        打开，另一条普通连接 SET TRANSACTION SNAPSHOT 复用该快照做基线，
        保证基线与复制流起点严格一致。兼容 PG 14/15/16。
        """
        conn = psycopg2.connect(self._settings.pg_dsn)
        conn.autocommit = False
        cur = conn.cursor()
        try:
            cur.execute("BEGIN")
            cur.execute(
                "SELECT lsn::text FROM pg_create_logical_replication_slot(%s, %s)",
                (slot_name, "test_decoding"),
            )
            consistent_lsn = cur.fetchone()[0]
            cur.execute("SELECT pg_export_snapshot()")
            snapshot_id = cur.fetchone()[0]
        except Exception:
            try:
                conn.close()
            except Exception:
                pass
            raise
        return consistent_lsn, conn, snapshot_id

    def baseline_rows_using_snapshot(self, snapshot_id: str) -> list[tuple]:
        """在普通连接上复用导出快照，读取基线时刻整目录。"""
        conn = psycopg2.connect(self._settings.pg_dsn)
        try:
            conn.autocommit = False
            with conn.cursor() as cur:
                cur.execute("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ")
                cur.execute("SET TRANSACTION SNAPSHOT %s", (snapshot_id,))
                cur.execute(
                    "SELECT artifact_no, service_name, version, sha256"
                    " FROM artifacts ORDER BY artifact_no"
                )
                rows = cur.fetchall()
            conn.rollback()  # 只读事务，回滚即可释放快照引用
            return rows
        finally:
            conn.close()
