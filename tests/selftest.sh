#!/usr/bin/env bash
# 端到端自测：在本机用便携 PostgreSQL + uvicorn 跑全链路验证。
# 用法：bash tests/selftest.sh
# 不依赖 Docker；Docker Compose 场景的启动方式见 README。
set -u
cd "$(dirname "$0")/.."
REPO=$PWD

# ------------------------------------------------------------- 环境定位
PGBIN=${PGBIN:-/tmp/pgdeb/extracted/usr/lib/postgresql/15/bin}
PGCLIENT=${PGCLIENT:-/tmp/pgdeb/client/usr/lib/postgresql/15/bin}
export PATH="$PGCLIENT:$PGBIN:$PATH"
PGDATA=${PGDATA:-/tmp/selftest-pgdata}
PGPORT=55433
PGSOCK=/tmp/selftest-pgsock
SQLDIR=/tmp/selftest-sqlite
APPPORT=8011
BASE="http://127.0.0.1:$APPPORT"
SHA64="a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
DSN="host=$PGSOCK port=$PGPORT dbname=postgres user=postgres"
PASS=0; FAIL=0

ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1' want '$2')"; fi; }
api()  { curl -s -m 10 "http://127.0.0.1:$APPPORT$1"; }
wait_phase(){ # wait_phase <expected> <timeout_s>
  local want=$1 deadline=$((SECONDS+$2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(api /api/progress | jq -r .phase)" = "$want" ] && return 0
    sleep 0.5
  done
  return 1
}
start_app(){ # start_app <sqlite_dir> [init_sleep_ms]
  local dir=$1 sleep_ms=${2:-0}
  stop_app
  for _ in $(seq 1 20); do
    curl -s -m 1 "http://127.0.0.1:$APPPORT/api/progress" >/dev/null 2>&1 || break
    sleep 0.5
  done
  mkdir -p "$dir"
  PG_DSN="$DSN" SQLITE_PATH="$dir/history.db" CAPTURE_INIT_SLEEP_MS="$sleep_ms" \
    setsid nohup python3 -m uvicorn app.main:app --host 127.0.0.1 \
    --port "$APPPORT" > /tmp/selftest-app.log 2>&1 < /dev/null &
  local new_pid=$!
  echo "$new_pid" > /tmp/selftest-app.pid
  _wait_app_ready "$new_pid"
}
# 带来源追踪测试钩子的启动：
# $2=TEST_EXIT_AFTER_COMMIT $3=TEST_DELAY_AFTER_COMMIT_S $4=TEST_CAPTURE_DELAY_MS
start_app_hooks(){ # start_app_hooks <sqlite_dir> <exit 0|1> <resp_delay_s> [capture_delay_ms]
  local dir=$1 do_exit=${2:-0} delay=${3:-0} capdelay=${4:-0}
  stop_app
  for _ in $(seq 1 20); do
    curl -s -m 1 "http://127.0.0.1:$APPPORT/api/progress" >/dev/null 2>&1 || break
    sleep 0.5
  done
  mkdir -p "$dir"
  PG_DSN="$DSN" SQLITE_PATH="$dir/history.db" \
    TEST_EXIT_AFTER_COMMIT="$do_exit" TEST_DELAY_AFTER_COMMIT_S="$delay" \
    TEST_CAPTURE_DELAY_MS="$capdelay" \
    setsid nohup python3 -m uvicorn app.main:app --host 127.0.0.1 \
    --port "$APPPORT" > /tmp/selftest-app.log 2>&1 < /dev/null &
  local new_pid=$!
  echo "$new_pid" > /tmp/selftest-app.pid
  _wait_app_ready "$new_pid"
}
wait_op_status(){ # wait_op_status <operation_id> <CAPTURED|PENDING_CAPTURE> <timeout_s>
  local id=$1 want=$2 deadline=$((SECONDS+$3))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(api "/api/operations/$id" | jq -r .status 2>/dev/null)" = "$want" ] && return 0
    sleep 0.5
  done
  return 1
}
_wait_app_ready(){ # _wait_app_ready <expected_pid>
  local expected=$1
  for _ in $(seq 1 40); do
    if ! kill -0 "$expected" 2>/dev/null; then
      echo "new app exited early:"; cat /tmp/selftest-app.log; return 1
    fi
    if curl -s -m 1 "http://127.0.0.1:$APPPORT/api/progress" >/dev/null 2>&1; then
      # 确认响应者确实是新进程而不是占用端口的旧实例
      [ "$(app_pid)" = "$expected" ] && return 0
    fi
    sleep 0.5
  done
  echo "app failed to become ready:"; cat /tmp/selftest-app.log; return 1
}
stop_app(){
  local pid
  pid=$(app_pid)
  [ -n "$pid" ] && kill $pid 2>/dev/null || true
  for _ in $(seq 1 20); do
    app_pid | grep -q . || return 0
    sleep 0.5
  done
}
force_kill_app(){
  local pid
  pid=$(app_pid)
  [ -n "$pid" ] && kill -9 $pid 2>/dev/null || true
  sleep 1
}
app_pid(){ ps -eo pid,comm,args | awk '$2=="python3" && /uvicorn app.main:app/ {print $1}'; }
pg_ctl_q(){ pg_ctl -D "$PGDATA" -l /tmp/selftest-pg.log "$@"; }

cleanup(){
  stop_app || true
  pg_ctl_q stop -m fast >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ------------------------------------------------------------- 0. 准备源库
echo "=== 0. 准备全新源 PostgreSQL（wal_level=logical）==="
pg_ctl_q stop -m fast >/dev/null 2>&1 || true
rm -rf "$PGDATA" "$PGSOCK" "$SQLDIR"; mkdir -p "$PGSOCK"
initdb -D "$PGDATA" -U postgres --auth=trust -E UTF8 --no-sync >/dev/null
cat >> "$PGDATA/postgresql.conf" <<EOF
port = $PGPORT
unix_socket_directories = '$PGSOCK'
listen_addresses = ''
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
EOF
pg_ctl_q start -w >/dev/null
psql -h "$PGSOCK" -p "$PGPORT" -U postgres -q -f init/01_schema.sql
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc 'select count(*) from artifacts')" \
      "3" "源表初始化 3 行示例数据"

# ------------------------------------------------------------- 1. 初始化未完成不开放历史（503）
echo "=== 1. 初始化窗口历史接口 503 ==="
start_app "$SQLDIR" 8000
sleep 1
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/points")
check "$code" "503" "INITIALIZING 期间 /api/points 返回 503"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/directory?point=0/1")
check "$code" "503" "INITIALIZING 期间 /api/directory 返回 503"
check "$(api /api/progress | jq -r .phase)" "INITIALIZING" "进度接口暴露 INITIALIZING"
wait_phase STREAMING 15 && ok "初始化完成进入 STREAMING" || bad "初始化超时"
base_lsn=$(api /api/points | jq -r '.points[]|select(.kind=="BASELINE").lsn')
[ -n "$base_lsn" ] && ok "基线提交点存在: $base_lsn" || bad "缺少基线提交点"
check "$(api "/api/directory?point=$base_lsn" | jq '.artifacts|length')" "3" "基线目录 3 行"

# ------------------------------------------------------------- 2. 基线前开始、基线后提交的事务不漏
echo "=== 2. 跨基线事务（初始化窗口开启，基线后提交）==="
stop_app; sleep 1
rm -rf "$SQLDIR"
# 同步等待旧槽完全删除，避免新实例误走 resume 分支
for _ in $(seq 1 20); do
  psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
    "select pg_drop_replication_slot(slot_name) from pg_replication_slots" 2>/dev/null || true
  n=$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
    "select count(*) from pg_replication_slots")
  [ "$n" = "0" ] && break
  sleep 0.5
done
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from pg_replication_slots")" "0" "旧复制槽已彻底删除，确保走全新基线"
# 清理历史失败运行可能残留的测试行（应用已停，不会再写入），
# 把源目录恢复到与 init/01_schema.sql 一致的 3 行初始状态
psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "delete from artifacts where artifact_no not in (1001,1002,1003)" >/dev/null
psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "insert into artifacts values
   (1001,'billing-gateway','1.4.2','a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90'),
   (1002,'risk-engine','2.7.0','0f1e2d3c4b5a69788796a5b4c3d2e1f009182736455463728190aabbccddeeff'),
   (1003,'notify-hub','0.9.3','ffeeddccbbaa9988776655443322110099887766554433221100998877665544')
   on conflict do nothing" >/dev/null
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc "select count(*) from artifacts")" \
      "3" "源目录已重置为 3 行初始状态"
# 用应用内置测试钩子确定性构造"基线前开始、基线后提交"的事务：
# 应用在建槽/基线前打开源事务写入 2001 并持有，基线落盘后才提交。
start_app_hook(){
  stop_app
  for _ in $(seq 1 20); do
    curl -s -m 1 "http://127.0.0.1:$APPPORT/api/progress" >/dev/null 2>&1 || break
    sleep 0.5
  done
  mkdir -p "$SQLDIR"
  PG_DSN="$DSN" SQLITE_PATH="$SQLDIR/history.db" \
    TEST_INFLIGHT_ARTIFACT_NO=2001 TEST_INFLIGHT_SLEEP_S=3 \
    setsid nohup python3 -m uvicorn app.main:app --host 127.0.0.1 \
    --port "$APPPORT" > /tmp/selftest-app.log 2>&1 < /dev/null &
  local new_pid=$!
  echo "$new_pid" > /tmp/selftest-app.pid
  _wait_app_ready "$new_pid"
}
start_app_hook || bad "带钩子的应用启动失败"
wait_phase STREAMING 20 || bad "钩子场景初始化超时"
grep -q "TEST hook: inflight transaction opened" /tmp/selftest-app.log \
  && ok "测试钩子事务已在基线前打开" \
  || bad "测试钩子未生效: $(grep -c 'TEST hook' /tmp/selftest-app.log)"
# 基线快照里不允许出现 2001（事务尚未提交）
new_base=$(api /api/points | jq -r '.points[]|select(.kind=="BASELINE").lsn')
check "$(api "/api/directory?point=$new_base" | jq '[.artifacts[]|select(.artifact_no==2001)]|length')" \
      "0" "跨基线事务未混入基线快照（不重）"
# 等钩子事务在基线后提交并被复制流捕获
for _ in $(seq 1 30); do
  n=$(api /api/history/2001 | jq '[.history[]|select(.change_type=="INSERT")]|length')
  [ "$n" = "1" ] && break
  sleep 1
done
found=$(api /api/history/2001 | jq '[.history[]|select(.change_type=="INSERT")]|length')
check "$found" "1" "基线前开始、基线后提交的事务被复制流补捕获，无遗漏"
sleep 2
inflight_lsn=$(api /api/points | jq -r '.points[-1].lsn')
check "$(api "/api/directory?point=$inflight_lsn" | jq '[.artifacts[]|select(.artifact_no==2001)]|length')" \
      "1" "跨基线事务在其提交点目录中可见"

# ------------------------------------------------------------- 3. 多行事务整体可见 + 删除后重用编号
echo "=== 3. 多行事务原子性与编号重用 ==="
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operations\":[
  {\"op\":\"insert\",\"artifact_no\":3001,\"service_name\":\"g1\",\"version\":\"1\",\"sha256\":\"$SHA64\"},
  {\"op\":\"insert\",\"artifact_no\":3002,\"service_name\":\"g2\",\"version\":\"1\",\"sha256\":\"$SHA64\"},
  {\"op\":\"delete\",\"artifact_no\":1002}
 ]}" >/dev/null
sleep 2
points=$(api /api/points | jq '[.points[]|select(.kind=="TXN" and .change_count>=3)]|length')
[ "$points" -ge 1 ] && ok "三行操作只产生一个提交点（整体可见）" || bad "多行事务被拆分"
latest=$(api /api/points | jq -r '.points[-1].lsn')
dir3001=$(api "/api/directory?point=$latest" | jq '[.artifacts[]|select(.artifact_no==3001)]|length')
dir1002=$(api "/api/directory?point=$latest" | jq '[.artifacts[]|select(.artifact_no==1002)]|length')
check "$dir3001" "1" "同事务插入的 3001 在提交点可见"
check "$dir1002" "0" "同事务删除的 1002 在提交点消失"
# 重用 1002
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operations\":[{\"op\":\"insert\",\"artifact_no\":1002,\"service_name\":\"reborn\",\"version\":\"2\",\"sha256\":\"$SHA64\"}]}" >/dev/null
sleep 2
chain=$(api /api/history/1002 | jq -r '[.history[].change_type]|join(",")')
case "$chain" in
  *BASELINE*DELETE*INSERT*) ok "删除后重用编号，旧历史完整保留: $chain" ;;
  *) bad "编号重用历史链异常: $chain" ;;
esac

# ------------------------------------------------------------- 4. 失败整组回滚 + 输入校验
echo "=== 4. 回滚与固定结构校验 ==="
code=$(curl -s -o /tmp/r.json -w '%{http_code}' -X POST "$BASE/api/source/operations" \
  -H 'Content-Type: application/json' -d "{
 \"operations\":[
  {\"op\":\"insert\",\"artifact_no\":9001,\"service_name\":\"ghost\",\"version\":\"1\",\"sha256\":\"$SHA64\"},
  {\"op\":\"delete\",\"artifact_no\":999999}
 ]}")
check "$code" "400" "组内失败返回 400"
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from artifacts where artifact_no=9001")" "0" "失败整组回滚，源库无残留"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/source/operations" \
  -H 'Content-Type: application/json' -d '{"operations":[{"op":"insert","artifact_no":1,"service_name":"x","version":"1","sha256":"bad"}]}')
check "$code" "422" "非法 sha256 被 pydantic 拒绝"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/directory?point=not-a-lsn")
check "$code" "400" "非法 LSN 参数 400"

# ------------------------------------------------------------- 5. 强杀应用后续接：无重复、无丢失、槽位不超前落盘
echo "=== 5. 强杀重启一致性 ==="
before_txns=$(api /api/progress | jq .captured_transactions)
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operations\":[{\"op\":\"update\",\"artifact_no\":1001,\"service_name\":\"billing-gateway\",\"version\":\"7.7.7\",\"sha256\":\"$SHA64\"}]}" >/dev/null
sleep 2
after_txns=$(api /api/progress | jq .captured_transactions)
[ "$after_txns" -gt "$before_txns" ] && ok "新事务已捕获 ($before_txns -> $after_txns)" || bad "新事务未捕获"
kill -9 "$(app_pid)" 2>/dev/null || true; sleep 2
start_app "$SQLDIR"
wait_phase STREAMING 15 || true
sleep 3
check "$(api /api/progress | jq .captured_transactions)" "$after_txns" "强杀重启后事务数不重复"
check "$(api /api/history/1001 | jq '[.history[]|select(.version=="7.7.7")]|length')" "1" "强杀前最后一次更新仍在"
flush=$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select confirmed_flush_lsn from pg_replication_slots where slot_name='artifacts_history_slot'")
last=$(api /api/progress | jq -r .last_commit_lsn)
if [ -n "$flush" ] && [ -n "$last" ]; then
  fnum=$(python3 -c "h,l='$flush'.split('/');print((int(h,16)<<32)+int(l,16))")
  lnum=$(python3 -c "h,l='$last'.split('/');print((int(h,16)<<32)+int(l,16))")
  [ "$fnum" -le "$lnum" ] && ok "槽 confirmed_flush_lsn($flush) 不超前已落盘提交点($last)" \
                            || bad "槽位超前落盘位置: $flush > $last"
fi
# 重启后再写一条，验证续接后的流仍然工作
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operations\":[{\"op\":\"update\",\"artifact_no\":1001,\"service_name\":\"billing-gateway\",\"version\":\"8.8.8\",\"sha256\":\"$SHA64\"}]}" >/dev/null
sleep 2
check "$(api /api/history/1001 | jq '[.history[]|select(.version=="8.8.8")]|length')" "1" "续接后新变更继续被捕获"

# ------------------------------------------------------------- 6. 源库断连恢复
echo "=== 6. 源库重启后自动重连续接 ==="
pg_ctl_q restart -w >/dev/null
sleep 1
for _ in $(seq 1 20); do
  api /api/progress | jq -e '.phase=="STREAMING"' >/dev/null && break
  sleep 1
done
check "$(api /api/progress | jq -r .phase)" "STREAMING" "源库重启后应用自动恢复 STREAMING"
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operations\":[{\"op\":\"update\",\"artifact_no\":1001,\"service_name\":\"billing-gateway\",\"version\":\"9.9.9\",\"sha256\":\"$SHA64\"}]}" >/dev/null
sleep 2
check "$(api /api/history/1001 | jq '[.history[]|select(.version=="9.9.9")]|length')" "1" "断连恢复后的变更未丢失"

# ------------------------------------------------------------- 8. 网页操作号随事务登记与显示
echo "=== 7. 网页成组操作的来源追踪（操作号随事务登记）==="
OP8="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
resp=$(curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operation_id\":\"$OP8\",
 \"operations\":[
  {\"op\":\"insert\",\"artifact_no\":4001,\"service_name\":\"origin-svc\",\"version\":\"1\",\"sha256\":\"$SHA64\"},
  {\"op\":\"update\",\"artifact_no\":1001,\"service_name\":\"billing-gateway\",\"version\":\"10.0.0\",\"sha256\":\"$SHA64\"}
 ]}")
check "$(echo "$resp" | jq -r .operation_id)" "$OP8" "响应回传同一网页操作号"
# 源库同事务登记
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from operation_origins where operation_id='$OP8'")" "1" "来源已在源库 operation_origins 登记"
wait_op_status "$OP8" CAPTURED 15 && ok "操作号状态变为已捕获" || bad "操作号未在超时内捕获"
st=$(api "/api/operations/$OP8")
check "$(echo "$st" | jq -r .status)" "CAPTURED" "操作号查询返回 CAPTURED"
check "$(echo "$st" | jq -r .audited)" "true" "已捕获操作号 audited=true"
[ -n "$(echo "$st" | jq -r .commit_lsn)" ] && ok "已捕获状态附提交点 LSN" || bad "已捕获状态缺少提交点"
# 提交点列表按事务显示操作号
pt=$(api /api/points | jq -r --arg id "$OP8" '.points[]|select(.operation_id==$id)|.operation_id')
check "$pt" "$OP8" "提交点列表按事务显示网页操作号"
# 单编号历史带出来源
check "$(api /api/history/4001 | jq -r '.history[-1].operation_id')" "$OP8" "单编号历史显示该事务操作号"

# 普通 SQL 直改目录：没有网页操作号，显示"来源未登记"
psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "insert into artifacts values (4002,'plain-sql','1','$SHA64')" >/dev/null
sleep 2
unreg=$(api /api/points | jq -r '[.points[]|select(.kind=="TXN" and (.origin_registered==false))]|length')
[ "$unreg" -ge 1 ] && ok "普通 SQL 事务标记为来源未登记" || bad "未找到来源未登记事务"
check "$(api /api/history/4002 | jq -r '.history[-1].operation_id // "NULL"')" "NULL" "普通 SQL 事务历史无操作号"
# 不存在/已回滚的操作号查不到（404），且不得显示为已审计
code=$(curl -s -o /tmp/r.json -w '%{http_code}' "$BASE/api/operations/op-does-not-exist-xx")
check "$code" "404" "不存在的操作号返回 404"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/source/operations" \
  -H 'Content-Type: application/json' -d '{"operation_id":"bad-id","operations":[{"op":"insert","artifact_no":1,"service_name":"x","version":"1","sha256":"'$SHA64'"}]}')
check "$code" "422" "非法操作号格式被 pydantic 拒绝"
# 同一操作号重复提交：409 冲突，整组回滚，不产生第二个事务/第二条来源
code=$(curl -s -o /tmp/r.json -w '%{http_code}' -X POST "$BASE/api/source/operations" \
  -H 'Content-Type: application/json' -d "{
   \"operation_id\":\"$OP8\",
   \"operations\":[{\"op\":\"insert\",\"artifact_no\":4011,\"service_name\":\"dup\",\"version\":\"1\",\"sha256\":\"$SHA64\"}]}")
check "$code" "409" "重复操作号提交返回 409 冲突"
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from operation_origins where operation_id='$OP8'")" "1" "冲突后来源登记仍只有一条"
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from artifacts where artifact_no=4011")" "0" "冲突整组回滚，目录无残留"
check "$(api /api/points | jq --arg id "$OP8" '[.points[]|select(.operation_id==$id)]|length')" "1" "冲突不产生重复事务"

# ------------------------------------------------------------- 9. 待捕获不得显示为已审计
echo "=== 8. 待捕获状态（源库已提交、SQLite 未捕获）==="
stop_app; sleep 1
OP9="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
# 应用停摆期间，在源库以单一事务同时写目录和来源登记（模拟已提交未捕获）
psql -h "$PGSOCK" -p "$PGPORT" -U postgres -v ON_ERROR_STOP=1 -q <<SQL
BEGIN;
INSERT INTO artifacts VALUES (4003,'pending-svc','1','$SHA64');
INSERT INTO operation_origins(operation_id, xid) VALUES ('$OP9', txid_current());
COMMIT;
SQL
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from operation_origins where operation_id='$OP9'")" "1" "停摆期间来源已在源库提交"

# 8a. 确定性待捕获窗口：捕获线程在每个 COMMIT 落盘前停留 4 秒，
#     期间查询必须返回 PENDING_CAPTURE 且 audited=false，绝不能显示为已审计。
start_app_hooks "$SQLDIR" 0 0 4000
wait_phase STREAMING 15 || true
# OP9 来自停摆期：应用一上线就会在 4 秒延迟窗口内处理它
for _ in $(seq 1 10); do
  s9=$(api "/api/operations/$OP9" | jq -r .status)
  [ "$s9" = "PENDING_CAPTURE" ] && break
  [ "$s9" = "CAPTURED" ] && break
  sleep 0.5
done
check "$s9" "PENDING_CAPTURE" "落盘前查询为待捕获（确定性窗口）"
check "$(api "/api/operations/$OP9" | jq -r .audited)" "false" "待捕获时 audited=false，不显示为已审计"
check "$(api "/api/operations/$OP9" | jq -r .source_xid)" \
  "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
     "select xid from operation_origins where operation_id='$OP9'")" \
  "待捕获响应回溯源库 xid"
# 在线新事务同样经过该窗口
OP9B="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operation_id\":\"$OP9B\",
 \"operations\":[{\"op\":\"insert\",\"artifact_no\":4009,\"service_name\":\"online-pending\",\"version\":\"1\",\"sha256\":\"$SHA64\"}]}" >/dev/null
for _ in $(seq 1 10); do
  s9b=$(api "/api/operations/$OP9B" | jq -r .status)
  [ "$s9b" = "PENDING_CAPTURE" ] && break
  [ "$s9b" = "CAPTURED" ] && break
  sleep 0.5
done
check "$s9b" "PENDING_CAPTURE" "在线事务捕获前同样只显示待捕获"
wait_op_status "$OP9" CAPTURED 20 && ok "重放后待捕获操作号转为已捕获" || bad "待捕获操作号始终未捕获"
wait_op_status "$OP9B" CAPTURED 20 || true
check "$(api "/api/operations/$OP9" | jq -r .audited)" "true" "捕获完成后才标记已审计"
check "$(api /api/history/4003 | jq '[.history[]|select(.change_type=="INSERT")]|length')" "1" "待捕获事务的目录变更最终入库"
# 来源不串事务：该操作号只关联一个事务，且相邻事务不带它
npt=$(api /api/points | jq --arg id "$OP9" '[.points[]|select(.operation_id==$id)]|length')
check "$npt" "1" "操作号只关联唯一事务，未串到相邻事务"
# 恢复正常启动（关闭捕获延迟钩子），避免影响后续章节时序
start_app "$SQLDIR"
wait_phase STREAMING 15 || true

# 8b. 响应挂起（未崩溃）：POST 响应延迟 3 秒返回期间，
#     另一个请求凭操作号已能查到状态——响应丢失不影响来源可追溯性。
start_app_hooks "$SQLDIR" 0 3 0
OP8B="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
curl -s -m 10 -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operation_id\":\"$OP8B\",
 \"operations\":[{\"op\":\"insert\",\"artifact_no\":4010,\"service_name\":\"slow-resp\",\"version\":\"1\",\"sha256\":\"$SHA64\"}]}" \
  >/tmp/r8b.json 2>&1 &
CURL_BG=$!
sleep 1   # 源事务已提交、POST 响应仍被钩子挂起
hold_status=$(api "/api/operations/$OP8B" | jq -r .status)
case "$hold_status" in
  PENDING_CAPTURE|CAPTURED) ok "响应挂起期间操作号已可查: $hold_status" ;;
  *) bad "响应挂起期间状态异常: $hold_status" ;;
esac
wait $CURL_BG
check "$(jq -r .operation_id /tmp/r8b.json)" "$OP8B" "挂起结束后响应正常返回同一操作号"
start_app "$SQLDIR"
wait_phase STREAMING 15 || true
wait_op_status "$OP8B" CAPTURED 15 || true

# ------------------------------------------------------------- 10. 回滚不留可查来源
echo "=== 9. 回滚事务不留下可查来源 ==="
OP10="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
code=$(curl -s -o /tmp/r.json -w '%{http_code}' -X POST "$BASE/api/source/operations" \
  -H 'Content-Type: application/json' -d "{
   \"operation_id\":\"$OP10\",
   \"operations\":[
    {\"op\":\"insert\",\"artifact_no\":4004,\"service_name\":\"rollback-svc\",\"version\":\"1\",\"sha256\":\"$SHA64\"},
    {\"op\":\"delete\",\"artifact_no\":999999}
   ]}")
check "$code" "400" "含失败操作的成组请求返回 400"
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from operation_origins where operation_id='$OP10'")" "0" "回滚后源库无来源登记残留"
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from artifacts where artifact_no=4004")" "0" "回滚后目录无残留"
sleep 1
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/operations/$OP10")
check "$code" "404" "回滚操作号查询为 404（不留可查来源）"
# 底层直连模拟回滚：登记与目录在同一事务里一起撤销
psql -h "$PGSOCK" -p "$PGPORT" -U postgres -q <<SQL
BEGIN;
INSERT INTO artifacts VALUES (4005,'rb2','1','$SHA64');
INSERT INTO operation_origins(operation_id, xid) VALUES ('op-rollback-direct', txid_current());
ROLLBACK;
SQL
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from operation_origins where operation_id='op-rollback-direct'")" "0" \
  "直连回滚同样不留来源登记"

# ------------------------------------------------------------- 11. 响应丢失：已提交但响应未返回
echo "=== 10. 网页响应丢失（源库已提交，客户端无响应）==="
start_app_hooks "$SQLDIR" 1 0   # 提交成功后进程退出，响应永不返回
OP11="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
curl -s -m 5 -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operation_id\":\"$OP11\",
 \"operations\":[{\"op\":\"insert\",\"artifact_no\":4006,\"service_name\":\"lost-resp\",\"version\":\"1\",\"sha256\":\"$SHA64\"}]}" \
  >/tmp/r11.json 2>/dev/null || true
[ ! -s /tmp/r11.json ] && ok "响应确实丢失（HTTP 无返回，进程已退出）" || bad "意外收到响应: $(cat /tmp/r11.json)"
sleep 1
# 源库中事务与来源都已提交
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from operation_origins where operation_id='$OP11'")" "1" "响应丢失但源库来源登记仍在"
check "$(psql -h "$PGSOCK" -p "$PGPORT" -U postgres -tAc \
  "select count(*) from artifacts where artifact_no=4006")" "1" "响应丢失但目录修改已提交"
# 应用已死：操作号在源库可查、尚未被捕获（404 仅指 SQLite 之外由源库兜底为 PENDING）
start_app "$SQLDIR"
wait_phase STREAMING 15 || true
# 重启后重放：来源与目录变更一起补齐，不缺失、不重复
wait_op_status "$OP11" CAPTURED 20 && ok "重连重放后操作号被捕获（来源不缺失）" || bad "重放后来源缺失"
st11=$(api "/api/operations/$OP11")
check "$(echo "$st11" | jq -r .status)" "CAPTURED" "响应丢失的操作号最终 CAPTURED"
check "$(api /api/history/4006 | jq '[.history[]|select(.change_type=="INSERT")]|length')" "1" "响应丢失事务的目录变更不丢"
check "$(api /api/points | jq --arg id "$OP11" '[.points[]|select(.operation_id==$id)]|length')" "1" "重放后操作号无重复关联"

# ------------------------------------------------------------- 12. 重放幂等与来源持久化（强杀重启）
echo "=== 11. 强杀重放：来源不重复、不缺失、不串事务 ==="
OP12="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operation_id\":\"$OP12\",
 \"operations\":[{\"op\":\"insert\",\"artifact_no\":4007,\"service_name\":\"replay-svc\",\"version\":\"1\",\"sha256\":\"$SHA64\"}]}" >/dev/null
wait_op_status "$OP12" CAPTURED 15 || true
before12=$(api /api/progress | jq .captured_transactions)
force_kill_app
start_app "$SQLDIR"
wait_phase STREAMING 15 || true
sleep 3
check "$(api /api/progress | jq .captured_transactions)" "$before12" "强杀重启后事务数不重复（含来源事务）"
check "$(api "/api/operations/$OP12" | jq -r .status)" "CAPTURED" "强杀重启后操作号仍可查且已捕获"
check "$(api /api/points | jq --arg id "$OP12" '[.points[]|select(.operation_id==$id)]|length')" "1" "重放后来源登记不重复"
# 再来一笔网页事务，验证续接流的来源追踪仍然工作
OP12B="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operation_id\":\"$OP12B\",
 \"operations\":[{\"op\":\"update\",\"artifact_no\":4007,\"service_name\":\"replay-svc\",\"version\":\"2\",\"sha256\":\"$SHA64\"}]}" >/dev/null
wait_op_status "$OP12B" CAPTURED 15 && ok "续接后新网页事务来源追踪正常" || bad "续接后来源追踪失效"
check "$(api /api/history/4007 | jq -r '[.history[]|select(.version=="2")][0].operation_id')" "$OP12B" "续接后新事务操作号正确关联"

# ------------------------------------------------------------- 13. 源库重启断线重连后的来源追踪
echo "=== 12. 断线重连后来源不丢不串 ==="
pg_ctl_q restart -w >/dev/null
sleep 1
for _ in $(seq 1 20); do
  api /api/progress | jq -e '.phase=="STREAMING"' >/dev/null && break
  sleep 1
done
check "$(api /api/progress | jq -r .phase)" "STREAMING" "源库重启后恢复 STREAMING"
OP13="op-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
curl -s -X POST "$BASE/api/source/operations" -H 'Content-Type: application/json' -d "{
 \"operation_id\":\"$OP13\",
 \"operations\":[{\"op\":\"insert\",\"artifact_no\":4008,\"service_name\":\"reconn-svc\",\"version\":\"1\",\"sha256\":\"$SHA64\"}]}" >/dev/null
wait_op_status "$OP13" CAPTURED 20 && ok "重连后网页事务来源被捕获" || bad "重连后来源丢失"
check "$(api /api/history/4008 | jq -r '.history[-1].operation_id')" "$OP13" "重连后操作号与事务正确关联"
# 旧事务仍标记来源未登记（升级前/普通 SQL 语义不能被改写）
check "$(api /api/points | jq '[.points[]|select(.kind=="TXN" and .origin_registered==false)]|length')" "$unreg" \
  "重连不改变旧事务的来源未登记语义"

# ------------------------------------------------------------- 7. 持久化校验
echo "=== 13. 两侧持久化 ==="
[ -f "$SQLDIR/history.db" ] && ok "SQLite 历史库落盘: $SQLDIR/history.db" || bad "SQLite 未落盘"
[ -d "$PGDATA/pg_wal" ] && ok "PostgreSQL 数据目录持久化: $PGDATA" || bad "PG 数据目录缺失"

echo
echo "================ 自测结果: $PASS passed / $FAIL failed ================"
[ "$FAIL" -eq 0 ]
