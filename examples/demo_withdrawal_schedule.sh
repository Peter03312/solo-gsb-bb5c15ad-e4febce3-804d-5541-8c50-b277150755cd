#!/usr/bin/env bash
# 快照计划撤回端到端示例：
#   发布快照 -> 安排未来撤回（缺密钥401/未知快照404/过去时间与空白原因422/不带时区422）->
#   重复提交相同内容返回原计划、改时间或原因 409 须先取消 ->
#   查询计划（按编号/按快照）-> 生效前取消（重复取消幂等）->
#   到点即视为撤回：公开读取 403 不扣次不写审计、执行器无流量也生效 ->
#   已生效计划取消 409 -> 手动撤回先发生则计划终止（superseded）->
#   计划先到时则手动撤回回放首次结果、不能改写原因
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

step "1. 创建记录并发布版本 1（签发一支上限 5 次的令牌）"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
RECORD_ID=$(echo "${CREATE}" | jq -r .record_id)
PUB=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 5}')
SID=$(echo "${PUB}" | jq -r .snapshot_id)
TOK=$(echo "${PUB}" | jq -r .token)
echo "快照 ${SID} 已发布"

step "2. 提交计划的明确拒绝：缺密钥 401、未知快照 404、过去时间/空白原因/不带时区 422"
FUTURE=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
PAST=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
printf '缺服务密钥:   HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" \
  -H 'Content-Type: application/json' -d "{\"scheduled_at\":\"${FUTURE}\",\"reason\":\"x\"}")"
printf '未知快照:     HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshots/00000000-0000-0000-0000-000000000000/withdrawal-schedules" \
  "${AUTH[@]}" -d "{\"scheduled_at\":\"${FUTURE}\",\"reason\":\"x\"}")"
printf '过去时间:     HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" \
  "${AUTH[@]}" -d "{\"scheduled_at\":\"${PAST}\",\"reason\":\"x\"}")"
printf '空白原因:     HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" \
  "${AUTH[@]}" -d "{\"scheduled_at\":\"${FUTURE}\",\"reason\":\"   \"}")"
printf '不带时区:     HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" \
  "${AUTH[@]}" -d '{"scheduled_at":"2027-01-01T00:00:00","reason":"x"}')"

step "3. 提交计划成功（201）：返回计划编号、预定时刻与状态"
AT1=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)
PLAN=$(curl -sS -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" "${AUTH[@]}" \
  -d "{\"scheduled_at\":\"${AT1}\",\"reason\":\"保留期届满，到期撤回\"}")
echo "${PLAN}" | jq .
PLAN_ID=$(echo "${PLAN}" | jq -r .schedule_id)

step "4. 重复提交相同内容（同一绝对时刻的不同时区表达）返回原计划（200, replayed=true）"
AT1_PLUS8=$(TZ=Asia/Shanghai date -d "${AT1}" +%Y-%m-%dT%H:%M:%S+08:00)
curl -sS -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" "${AUTH[@]}" \
  -d "{\"scheduled_at\":\"${AT1_PLUS8}\",\"reason\":\"保留期届满，到期撤回\"}" \
  | jq '{schedule_id, status, replayed}'

step "5. 改时间或原因须先取消：均 409"
AT2=$(date -u -d '+3 hours' +%Y-%m-%dT%H:%M:%SZ)
printf '改时间: HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" \
  "${AUTH[@]}" -d "{\"scheduled_at\":\"${AT2}\",\"reason\":\"保留期届满，到期撤回\"}")"
printf '改原因: HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" \
  "${AUTH[@]}" -d "{\"scheduled_at\":\"${AT1}\",\"reason\":\"另一个原因\"}")"

step "6. 查询计划：按计划编号 / 按快照列出"
curl -sS "${BASE_URL}/withdrawal-schedules/${PLAN_ID}" "${AUTH[@]}" | jq .
curl -sS "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" "${AUTH[@]}" \
  | jq '{snapshot_id, schedules: [.schedules[] | {schedule_id, status, scheduled_at}]}'

step "7. 生效前取消（重复取消幂等）；取消后读取不受影响、可重新安排"
curl -sS -X POST "${BASE_URL}/withdrawal-schedules/${PLAN_ID}/cancel" "${AUTH[@]}" | jq .
curl -sS -X POST "${BASE_URL}/withdrawal-schedules/${PLAN_ID}/cancel" "${AUTH[@]}" \
  | jq '{status, already_canceled}'
printf '取消后公开读取: HTTP %s\n' "$(code "${BASE_URL}/public/snapshots/${SID}?token=${TOK}")"
PLAN2=$(curl -sS -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" "${AUTH[@]}" \
  -d "{\"scheduled_at\":\"${AT2}\",\"reason\":\"改期后的撤回计划\"}")
PLAN2_ID=$(echo "${PLAN2}" | jq -r .schedule_id)
echo "取消后重新安排成功：${PLAN2_ID}"
curl -sS -X POST "${BASE_URL}/withdrawal-schedules/${PLAN2_ID}/cancel" "${AUTH[@]}" >/dev/null

step "8. 到点即视为撤回：安排 3 秒后撤回，到点后公开读取 403（不扣次、不写审计）"
SOON=$(date -u -d '+3 seconds' +%Y-%m-%dT%H:%M:%SZ)
PLAN3=$(curl -sS -X POST "${BASE_URL}/snapshots/${SID}/withdrawal-schedules" "${AUTH[@]}" \
  -d "{\"scheduled_at\":\"${SOON}\",\"reason\":\"计划到期，自动撤回\"}")
PLAN3_ID=$(echo "${PLAN3}" | jq -r .schedule_id)
echo "到点前读取: HTTP $(code "${BASE_URL}/public/snapshots/${SID}?token=${TOK}")（消耗 1 次）"
echo "等待到点（后台执行器按周期结算，无需任何流量）..."; sleep 5
curl -sS "${BASE_URL}/withdrawal-schedules/${PLAN3_ID}" "${AUTH[@]}" \
  | jq '{status, scheduled_at, executed_at, reason}'
printf '到点后公开读取: HTTP %s  ' "$(code "${BASE_URL}/public/snapshots/${SID}?token=${TOK}")"
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${TOK}"; echo
echo "到点后的 403 未消耗次数（到点前共读取 2 次：第 7 步与第 8 步各 1 次）:"
curl -sS "${BASE_URL}/tokens/${TOK}" "${AUTH[@]}" | jq '{max_reads, reads_used, remaining_reads}'
echo "维护侧快照状态：撤回时刻=计划预定时刻、原因=计划原因"
curl -sS "${BASE_URL}/records/${RECORD_ID}" "${AUTH[@]}" \
  | jq '.snapshots[0] | {status, withdrawn_at, withdraw_reason}'

step "9. 已生效计划的取消被明确拒绝（409）"
printf '取消已生效计划: HTTP %s\n' "$(code -X POST "${BASE_URL}/withdrawal-schedules/${PLAN3_ID}/cancel" "${AUTH[@]}")"

step "10. 手动撤回先发生：以手动撤回时间和原因为准，计划终止（superseded）"
CREATE2=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "另一条记录，版本一内容。", "intervals": [{"start": 4, "end": 7}]}')
RID2=$(echo "${CREATE2}" | jq -r .record_id)
PUB2=$(curl -sS -X POST "${BASE_URL}/records/${RID2}/publish" "${AUTH[@]}" -d '{"version": 1}')
SID2=$(echo "${PUB2}" | jq -r .snapshot_id)
FAR=$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)
P_A=$(curl -sS -X POST "${BASE_URL}/snapshots/${SID2}/withdrawal-schedules" "${AUTH[@]}" \
  -d "{\"scheduled_at\":\"${FAR}\",\"reason\":\"计划原因（不会生效）\"}" | jq -r .schedule_id)
curl -sS -X POST "${BASE_URL}/snapshots/${SID2}/withdraw" "${AUTH[@]}" \
  -d '{"reason":"手动撤回原因（先生效）"}' | jq .
curl -sS "${BASE_URL}/withdrawal-schedules/${P_A}" "${AUTH[@]}" \
  | jq '{status, superseded_at}'
curl -sS "${BASE_URL}/records/${RID2}" "${AUTH[@]}" \
  | jq '.snapshots[0] | {status, withdraw_reason}'

step "11. 计划先到时：手动撤回回放首次结果，不能改写原因"
CREATE3=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "第三条记录，版本一内容。", "intervals": [{"start": 4, "end": 7}]}')
RID3=$(echo "${CREATE3}" | jq -r .record_id)
PUB3=$(curl -sS -X POST "${BASE_URL}/records/${RID3}/publish" "${AUTH[@]}" -d '{"version": 1}')
SID3=$(echo "${PUB3}" | jq -r .snapshot_id)
SOON3=$(date -u -d '+2 seconds' +%Y-%m-%dT%H:%M:%SZ)
P_B=$(curl -sS -X POST "${BASE_URL}/snapshots/${SID3}/withdrawal-schedules" "${AUTH[@]}" \
  -d "{\"scheduled_at\":\"${SOON3}\",\"reason\":\"计划原因（先生效）\"}" | jq -r .schedule_id)
echo "等待计划到点..."; sleep 4
echo "计划状态: $(curl -sS "${BASE_URL}/withdrawal-schedules/${P_B}" "${AUTH[@]}" | jq -r .status)"
curl -sS -X POST "${BASE_URL}/snapshots/${SID3}/withdraw" "${AUTH[@]}" \
  -d '{"reason":"试图改写的手动原因"}' | jq .
echo "撤回时刻为计划预定时刻、原因保持计划原因（未被改写）:"
curl -sS "${BASE_URL}/records/${RID3}" "${AUTH[@]}" \
  | jq '.snapshots[0] | {status, withdrawn_at, withdraw_reason}'

printf '\n\033[1m快照计划撤回演示完成。\033[0m\n'
