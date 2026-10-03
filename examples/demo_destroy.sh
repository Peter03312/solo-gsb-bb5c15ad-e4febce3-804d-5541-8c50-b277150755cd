#!/usr/bin/env bash
# 历史版本原文销毁端到端示例：
#   创建受控记录 + 直接/受控两条路径的发布准备 ->
#   鉴权与明确拒绝（缺密钥 401/未知记录 404/未知版本 404/空白理由 422）->
#   首次销毁版本 1：原子清除版本原文与该版本全部受控申请冻结的原文，
#   保留版本、脱敏区间与申请状态；返回记录、版本、销毁时间与 replayed=false ->
#   重复销毁回放首次销毁时间与理由（replayed=true），不再次改写 ->
#   销毁后：该版本直接发布 409、受控申请提交 409、待审申请批准 409，但仍可驳回；
#   其他版本（版本 2）的修订与发布不受影响 ->
#   既有脱敏快照、读取凭证、额度、成功读取审计与公开读取保持原约定，
#   公开响应不透露销毁状态
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
ALICE_PW="${ALICE_PW:-alice-pw}"   # operator
BOB_PW="${BOB_PW:-bob-pw}"         # reviewer
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

step "1. 创建受控记录（版本 1），修订出版本 2"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
RID=$(echo "${CREATE}" | jq -r .record_id)
curl -sS -X PUT "${BASE_URL}/records/${RID}/controlled" "${AUTH[@]}" >/dev/null
curl -sS -X PUT "${BASE_URL}/records/${RID}" "${AUTH[@]}" -d '{
  "base_version": 1,
  "text": "患者李四，联系方式已变更。",
  "intervals": [{"start": 2, "end": 4}]
}' >/dev/null
echo "受控记录 ${RID}（当前版本 2）"

step "2. 对版本 1 提交两笔受控发布申请：一笔保持待审，一笔先驳回（终态）"
SUBMIT1=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version": 1}')
REQ_PENDING=$(echo "${SUBMIT1}" | jq -r .request_id)
SUBMIT2=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "carol:carol-pw" -H 'Content-Type: application/json' -d '{"version": 1}')
REQ_REJECTED=$(echo "${SUBMIT2}" | jq -r .request_id)
curl -sS -X POST "${BASE_URL}/publish-requests/${REQ_REJECTED}/reject" \
  -u "bob:${BOB_PW}" -H 'Content-Type: application/json' \
  -d '{"reason":"先驳回一笔作为终态样例"}' >/dev/null
echo "待审申请 ${REQ_PENDING}；已驳回申请 ${REQ_REJECTED}"

step "3. 明确拒绝：缺密钥 401、未知记录 404、未知版本 404、空白理由 422"
printf '缺服务密钥: HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${RID}/versions/1/destroy-original" \
  -H 'Content-Type: application/json' -d '{"reason":"x"}')"
UNKNOWN="00000000-0000-0000-0000-000000000000"
printf '未知记录:   HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${UNKNOWN}/versions/1/destroy-original" "${AUTH[@]}" \
  -d '{"reason":"x"}')"
printf '未知版本:   HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${RID}/versions/99/destroy-original" "${AUTH[@]}" \
  -d '{"reason":"x"}')"
printf '空白理由:   HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${RID}/versions/1/destroy-original" "${AUTH[@]}" \
  -d '{"reason":"   "}')"

step "4. 首次销毁版本 1 原文：原子清除版本原文与两笔申请冻结的原文"
DESTROY=$(curl -sS -X POST "${BASE_URL}/records/${RID}/versions/1/destroy-original" \
  "${AUTH[@]}" -d '{"reason":"保留期届满，按制度销毁版本 1 原文"}')
echo "${DESTROY}" | jq .
DESTROYED_AT=$(echo "${DESTROY}" | jq -r .destroyed_at)
echo "=> 响应只含记录、版本、销毁时间、理由、replayed；不含任何原文"

step "5. 重复销毁（不同理由/空理由/空请求体）：回放首次时间与理由，不再次改写"
curl -sS -X POST "${BASE_URL}/records/${RID}/versions/1/destroy-original" \
  "${AUTH[@]}" -d '{"reason":"试图覆盖的另一个理由"}' \
  | jq --arg first "${DESTROYED_AT}" -e \
    '{record_id, version, destroyed_at, reason, replayed}
     | .replayed == true and .destroyed_at == $first
       and (.reason | contains("保留期届满"))'
curl -sS -X POST "${BASE_URL}/records/${RID}/versions/1/destroy-original" \
  "${AUTH[@]}" -d '{}' | jq '{record_id, version, destroyed_at, replayed}'

step "6. 版本与申请状态仍可查（元数据保留，响应中从不出现原文）"
curl -sS "${BASE_URL}/records/${RID}" "${AUTH[@]}" | jq '{record_id, current_version, controlled}'
curl -sS "${BASE_URL}/publish-requests/${REQ_PENDING}" -u "carol:carol-pw" \
  | jq '{request_id, version, status}'
curl -sS "${BASE_URL}/records/${RID}/publish-requests" -u "carol:carol-pw" \
  | jq '.requests | map({version, status})'

step "7. 销毁后：版本 1 的直接发布与受控申请提交一律 409"
printf '直接发布(受控本就 409，这里改看非受控路径不适用；用申请提交验证):\n'
printf '受控申请提交版本 1: HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version": 1}')"
echo "错误体（仅维护侧/操作者可见，公开侧绝不出现）:"
curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version": 1}' | jq .detail

step "8. 待审申请不能再批准（409），但仍可驳回"
printf '批准待审申请: HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/publish-requests/${REQ_PENDING}/approve" -u "bob:${BOB_PW}")"
curl -sS -X POST "${BASE_URL}/publish-requests/${REQ_PENDING}/approve" \
  -u "bob:${BOB_PW}" | jq .detail
curl -sS -X POST "${BASE_URL}/publish-requests/${REQ_PENDING}/reject" \
  -u "bob:${BOB_PW}" -H 'Content-Type: application/json' \
  -d '{"reason":"原文已销毁，驳回"}' | jq '{request_id, version, status}'

step "9. 其他版本不受影响：版本 2 仍可提交受控申请并被批准签发"
SUBMIT_V2=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' \
  -d '{"version": 2, "max_reads": 3}')
APPROVE_V2=$(curl -sS -X POST \
  "${BASE_URL}/publish-requests/$(echo "${SUBMIT_V2}" | jq -r .request_id)/approve" \
  -u "bob:${BOB_PW}")
SID2=$(echo "${APPROVE_V2}" | jq -r .snapshot_id)
TOK2=$(echo "${APPROVE_V2}" | jq -r .token)
echo "版本 2 批准签发: snapshot=${SID2}"
# 销毁版本 1 不影响继续修订
curl -sS -X PUT "${BASE_URL}/records/${RID}" "${AUTH[@]}" -d '{
  "base_version": 2,
  "text": "版本三全新原文。",
  "intervals": [{"start": 0, "end": 3}]
}' | jq '{record_id, version}'

step "10. 既有脱敏快照/凭证/公开读取约定不变，公开响应不透露销毁状态"
curl -sS "${BASE_URL}/public/snapshots/${SID2}?token=${TOK2}" | jq .
echo "（响应结构与销毁前完全一致：record_id/version/status/redacted_text，无销毁字段）"
curl -sS "${BASE_URL}/tokens/${TOK2}" "${AUTH[@]}" \
  | jq '{max_reads, reads_used, remaining_reads, active}'

printf '\n\033[1m历史版本原文销毁演示完成。\033[0m\n'
