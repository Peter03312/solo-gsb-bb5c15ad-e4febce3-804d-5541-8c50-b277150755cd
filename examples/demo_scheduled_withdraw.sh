#!/usr/bin/env bash
# 快照定时永久撤回端到端示例：
#   发布快照 -> 安排未来撤回（缺密钥401/未知404/过去时刻422/空白原因422/缺时区422）->
#   查询计划 -> 重复提交相同内容回放原计划（replayed=true）-> 改时间须先取消（409）->
#   取消后重新安排一个 3 秒后生效的计划 -> 到点自动撤回（后台结算）->
#   公开读取沿用模糊 403，不扣令牌次数、不写成功审计 -> 手动撤回只回放首次结果，不能改原因 ->
#   再演示“手动撤回先发生”：计划终止为 superseded，撤回时间与原因以手动为准
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

step "1. 创建记录并发布快照（签发一支上限 5 次的令牌）"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
RECORD_ID=$(echo "${CREATE}" | jq -r .record_id)
PUB=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 5}')
SID=$(echo "${PUB}" | jq -r .snapshot_id)
TOK=$(echo "${PUB}" | jq -r .token)
echo "snapshot_id=${SID}  token=${TOK}"

step "2. 安排未来撤回：带时区时刻（+08:00）+ 非空原因，返回计划编号/预定时刻/状态"
SCHED_AT="2099-12-31T20:00:00+08:00"
PLAN=$(curl -sS -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" -d "{
  \"snapshot_id\": \"${SID}\",
  \"scheduled_at\": \"${SCHED_AT}\",
  \"reason\": \"合规要求到期永久撤回\"
}")
echo "${PLAN}" | jq .
PLAN_ID=$(echo "${PLAN}" | jq -r .plan_id)
# 服务端统一回显为 UTC：2099-12-31T12:00:00Z
echo "${PLAN}" | jq -e '.status == "pending" and .ended_at == null and .replayed == false' >/dev/null

step "3. 明确拒绝：缺密钥 401 / 未知快照 404 / 过去时刻 422 / 缺时区 422 / 空白原因 422"
printf '缺服务密钥: HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshot-withdrawal-plans" \
  -H 'Content-Type: application/json' \
  -d "{\"snapshot_id\":\"${SID}\",\"scheduled_at\":\"2099-01-01T00:00:00Z\",\"reason\":\"x\"}")"
printf '未知快照:   HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" \
  -d '{"snapshot_id":"00000000-0000-0000-0000-000000000000","scheduled_at":"2099-01-01T00:00:00Z","reason":"x"}')"
printf '过去时刻:   HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" \
  -d "{\"snapshot_id\":\"${SID}\",\"scheduled_at\":\"2000-01-01T00:00:00Z\",\"reason\":\"x\"}")"
printf '缺时区:     HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" \
  -d "{\"snapshot_id\":\"${SID}\",\"scheduled_at\":\"2099-01-01T00:00:00\",\"reason\":\"x\"}")"
printf '空白原因:   HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" \
  -d "{\"snapshot_id\":\"${SID}\",\"scheduled_at\":\"2099-01-01T00:00:00Z\",\"reason\":\"   \"}")"

step "4. 查询计划（编号、快照、预定时刻、原因、状态；到点查询会即时反映 completed）"
curl -sS "${BASE_URL}/snapshot-withdrawal-plans/${PLAN_ID}" "${AUTH[@]}" | jq .

step "5. 重复提交相同内容（等价时区写法 + 同一原因）：返回原计划，200 + replayed=true"
curl -sS -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" -d "{
  \"snapshot_id\": \"${SID}\",
  \"scheduled_at\": \"2099-12-31T12:00:00Z\",
  \"reason\": \"合规要求到期永久撤回\"
}" | jq '{plan_id, status, replayed}'

step "6. 改时间或原因须先取消：不同内容 -> 409（响应带回既有 plan_id 与 scheduled_at）"
curl -sS -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" -d "{
  \"snapshot_id\": \"${SID}\",
  \"scheduled_at\": \"2099-12-30T12:00:00Z\",
  \"reason\": \"合规要求到期永久撤回\"
}" | jq .

step "7. 生效前取消：200 status=cancelled；重复取消 -> 409"
curl -sS -X POST "${BASE_URL}/snapshot-withdrawal-plans/${PLAN_ID}/cancel" "${AUTH[@]}" | jq .
printf '重复取消: HTTP %s（已终结计划的取消一律明确拒绝）\n' \
  "$(code -X POST "${BASE_URL}/snapshot-withdrawal-plans/${PLAN_ID}/cancel" "${AUTH[@]}")"

step "8. 取消后重新安排一个 3 秒后生效的计划；撤回前公开读取仍 200"
DUE_AT=$(date -u -d '+3 seconds' +%Y-%m-%dT%H:%M:%SZ)
PLAN2=$(curl -sS -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" -d "{
  \"snapshot_id\": \"${SID}\",
  \"scheduled_at\": \"${DUE_AT}\",
  \"reason\": \"按计划到期撤回\"
}")
echo "${PLAN2}" | jq '{plan_id, scheduled_at, status, reason}'
PLAN2_ID=$(echo "${PLAN2}" | jq -r .plan_id)
echo "撤回前读取: HTTP $(code "${BASE_URL}/public/snapshots/${SID}?token=${TOK}")"

step "9. 等到点：后台结算自动撤回（无需任何请求；重启/多实例也不漏执行、不重复执行）"
for _ in $(seq 1 30); do
  STATUS=$(curl -sS "${BASE_URL}/snapshot-withdrawal-plans/${PLAN2_ID}" "${AUTH[@]}" | jq -r .status)
  [ "${STATUS}" = "completed" ] && break
  sleep 0.5
done
echo "计划最终状态: ${STATUS}"
curl -sS "${BASE_URL}/snapshot-withdrawal-plans/${PLAN2_ID}" "${AUTH[@]}" \
  | jq '{plan_id, status, scheduled_at, ended_at, withdrawn_at, reason}'

step "10. 到点后的公开读取沿用模糊 403：不扣令牌额度、不写成功审计、不透露原因"
printf '读取 HTTP %s: ' "$(code "${BASE_URL}/public/snapshots/${SID}?token=${TOK}")"
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${TOK}"; echo
curl -sS "${BASE_URL}/tokens/${TOK}" "${AUTH[@]}" \
  | jq '{max_reads, reads_used, remaining_reads, active}'
EVENTS=$(curl -sS "${BASE_URL}/snapshots/${SID}/read-events?start=2000-01-01T00:00:00Z&end=2100-01-01T00:00:00Z" \
  "${AUTH[@]}" | jq '.events | length')
echo "成功读取审计事件数（撤回后的 403 不写事件；仅步骤 8 的一次 200）: ${EVENTS}"

step "11. 计划先到点后，手动撤回只回放首次结果：撤回时间=预定时刻、原因不可改写"
curl -sS -X POST "${BASE_URL}/snapshots/${SID}/withdraw" "${AUTH[@]}" \
  -d '{"reason":"试图用手动原因改写"}' | jq .
curl -sS "${BASE_URL}/records/${RECORD_ID}" "${AUTH[@]}" \
  | jq '.snapshots[0] | {status, withdrawn_at, withdraw_reason}'

step "12. 另一快照演示“手动撤回先发生”：计划终止为 superseded，以手动时间和原因为准"
PUB2=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "另一条记录，示例内容。", "intervals": [{"start": 0, "end": 3}]}')
RID2=$(echo "${PUB2}" | jq -r .record_id)
PUB3=$(curl -sS -X POST "${BASE_URL}/records/${RID2}/publish" "${AUTH[@]}" -d '{"version": 1}')
SID2=$(echo "${PUB3}" | jq -r .snapshot_id)
PLAN3=$(curl -sS -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" -d "{
  \"snapshot_id\": \"${SID2}\",
  \"scheduled_at\": \"2099-12-31T12:00:00Z\",
  \"reason\": \"计划中的未来原因\"
}")
PLAN3_ID=$(echo "${PLAN3}" | jq -r .plan_id)
curl -sS -X POST "${BASE_URL}/snapshots/${SID2}/withdraw" "${AUTH[@]}" \
  -d '{"reason":"手动提前撤回原因"}' | jq .
echo "计划状态变为 superseded（withdrawn_at 为 null，ended_at 为手动撤回时刻）:"
curl -sS "${BASE_URL}/snapshot-withdrawal-plans/${PLAN3_ID}" "${AUTH[@]}" | jq .
echo "快照撤回时间与原因以手动为准:"
curl -sS "${BASE_URL}/records/${RID2}" "${AUTH[@]}" \
  | jq '.snapshots[0] | {status, withdrawn_at, withdraw_reason}'

printf '\n\033[1m快照定时撤回演示完成。\033[0m\n'
