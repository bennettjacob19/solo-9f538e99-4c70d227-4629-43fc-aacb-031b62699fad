"""FastAPI 历史查询网页：源目录成组修改、提交点查询、捕获进度。

初始化未完成（phase != STREAMING）时，所有历史查询接口返回 503，
不对外开放尚未完整的历史；源目录修改走源库自身事务，不受此限制。
"""
from __future__ import annotations

import logging
import os
import re
import uuid
from contextlib import asynccontextmanager
from typing import Annotated, Literal, Union

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field, field_validator

from .capture import CaptureWorker
from .config import settings
from .source import OperationIdConflict, SourceDB, SourceError
from .storage import HistoryStore, lsn_to_num

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("web")

SHA256_RE = r"^[0-9a-fA-F]{64}$"
# 网页操作号：UUID（带/不带连字符）或 op-/web- 前缀的 8-64 位安全字符
OPERATION_ID_RE = re.compile(r"^[A-Za-z0-9._-]{8,64}$")


def _check_sha(v: str) -> str:
    if not re.match(SHA256_RE, v):
        raise ValueError("sha256 必须是 64 位十六进制")
    return v


def _check_operation_id(v: str) -> str:
    if not OPERATION_ID_RE.match(v):
        raise ValueError(
            "operation_id 需为 8-64 位字母数字及 ._- 字符（建议使用 UUID）"
        )
    return v


class _Columns(BaseModel):
    """增/改共用的四列固定字段，严格拒绝额外列。"""

    artifact_no: int = Field(gt=0)
    service_name: str = Field(min_length=1, max_length=200)
    version: str = Field(min_length=1, max_length=100)
    sha256: str

    @field_validator("sha256")
    @classmethod
    def _sha(cls, v: str) -> str:
        return _check_sha(v)


class InsertOp(_Columns):
    op: Literal["insert"]


class UpdateOp(_Columns):
    op: Literal["update"]


class DeleteOp(BaseModel):
    op: Literal["delete"]
    artifact_no: int = Field(gt=0)


AnyOp = Annotated[
    Union[InsertOp, UpdateOp, DeleteOp], Field(discriminator="op")
]


class BatchRequest(BaseModel):
    operations: list[AnyOp] = Field(min_length=1)
    # 网页先生成操作号再随整组修改发送；缺省时服务端补生成。
    operation_id: str | None = None

    @field_validator("operation_id")
    @classmethod
    def _opid(cls, v: str | None) -> str | None:
        return _check_operation_id(v) if v is not None else v


store = HistoryStore(settings.sqlite_path)
source = SourceDB(settings)
worker = CaptureWorker(store, source, settings)


@asynccontextmanager
async def lifespan(app: FastAPI):
    worker.start()
    try:
        yield
    finally:
        worker.stop()
        store.close()


app = FastAPI(title="制品目录历史查询", lifespan=lifespan)


def _require_ready() -> None:
    if not store.is_ready():
        progress = store.get_progress()
        raise HTTPException(
            status_code=503,
            detail={
                "message": "捕获初始化尚未完成，历史暂不开放",
                "phase": progress.get("phase"),
                "last_error": progress.get("last_error"),
            },
        )


# --------------------------------------------------------------------- 页面
@app.get("/", include_in_schema=False)
def index() -> FileResponse:
    return FileResponse(
        os.path.join(os.path.dirname(__file__), "static", "index.html")
    )


# --------------------------------------------------------------------- 进度
@app.get("/api/progress")
def api_progress() -> dict:
    return store.get_progress()


# --------------------------------------------------------------- 源目录读写
@app.get("/api/source/artifacts")
def api_source_list() -> dict:
    return {"artifacts": source.list_artifacts()}


@app.post("/api/source/operations")
def api_batch_write(req: BatchRequest) -> dict:
    """成组修改源目录；整组在一个源事务内提交，失败整体回滚。

    网页操作号与目录修改在同一源事务登记：提交则同生，回滚则同灭。
    响应可能丢失（网络/进程重启），但操作号已随事务持久化在源库，
    客户端可用 GET /api/operations/{id} 查询最终状态。
    """
    operation_id = req.operation_id or f"op-{uuid.uuid4().hex}"
    payload = [op.model_dump() for op in req.operations]
    try:
        result = source.apply_operations(payload, operation_id)
    except OperationIdConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except SourceError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"源库错误: {exc}")

    # 测试钩子：源事务已提交，HTTP 响应尚未返回 —— 模拟"响应丢失"。
    # 数据与来源登记都已在源库提交，查询接口必须仍能给出正确状态。
    if settings.exit_after_commit:
        log.warning(
            "TEST hook: source txn committed (operation_id=%s),"
            " exiting before HTTP response", operation_id,
        )
        os._exit(2)
    if settings.delay_after_commit_s > 0:
        import time

        log.warning(
            "TEST hook: holding response %.1fs after commit (%s)",
            settings.delay_after_commit_s, operation_id,
        )
        time.sleep(settings.delay_after_commit_s)

    result["operations"] = len(payload)
    result["operation_id"] = operation_id
    return result


@app.get("/api/operations/{operation_id}")
def api_operation_status(operation_id: str) -> dict:
    """按网页操作号查询待捕获/已捕获状态。

    - 已在 SQLite：CAPTURED（已捕获、已审计），附提交点与变更行数；
    - 仅在源库登记表：PENDING（源库已提交、尚未被捕获），绝不显示为已审计；
    - 两边都没有：404（操作号不存在，或其源事务已回滚——回滚不留可查来源）。
    """
    if not OPERATION_ID_RE.match(operation_id):
        raise HTTPException(status_code=400, detail="非法操作号格式")

    captured = store.get_operation(operation_id)
    if captured is not None:
        return {
            "operation_id": operation_id,
            "status": "CAPTURED",
            "audited": True,
            "capture_state": store.get_phase(),
            **captured,
        }

    try:
        origin = source.get_origin(operation_id)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"源库查询失败: {exc}")
    if origin is None:
        raise HTTPException(
            status_code=404,
            detail="操作号不存在：未提交或其源事务已回滚（回滚不留下可查来源）",
        )
    # 源库已提交但还没出现在 SQLite —— 明确是待捕获，不能标已审计
    return {
        "operation_id": operation_id,
        "status": "PENDING_CAPTURE",
        "audited": False,
        "source_xid": origin["xid"],
        "source_created_at": origin["created_at"],
        "capture_state": store.get_phase(),
    }


# ---------------------------------------------------------------- 历史查询
@app.get("/api/points")
def api_points() -> dict:
    _require_ready()
    return {"points": store.get_points()}


@app.get("/api/directory")
def api_directory(point: str) -> JSONResponse:
    """按提交点（LSN，如 0/16B3748）查看该时刻的整张目录。"""
    _require_ready()
    try:
        lsn_num = lsn_to_num(point)
    except (ValueError, IndexError):
        raise HTTPException(status_code=400, detail="point 必须是 LSN，形如 0/16B3748")
    points = store.get_points()
    valid_nums = {p["lsn_num"] for p in points}
    if lsn_num not in valid_nums:
        raise HTTPException(
            status_code=404,
            detail="该 LSN 不是已捕获的提交点，请先在 /api/points 中选择",
        )
    return JSONResponse(
        {
            "point": point,
            "point_lsn_num": lsn_num,
            "artifacts": store.get_directory_at(lsn_num),
        }
    )


@app.get("/api/history/{artifact_no}")
def api_artifact_history(artifact_no: int) -> dict:
    """单个制品编号的完整变更链；删除后重用编号，旧历史也全部保留。"""
    _require_ready()
    return {
        "artifact_no": artifact_no,
        "history": store.get_history_of(artifact_no),
    }
