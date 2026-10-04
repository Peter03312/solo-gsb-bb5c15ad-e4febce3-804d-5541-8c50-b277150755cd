"""快照计划撤回端到端集成测试：需要真实 PostgreSQL。

默认尝试用 pgserver（pip 包，内置 Postgres 16 二进制）自动拉起临时库；
也可通过环境变量 TEST_DATABASE_URL 指定已有数据库。

运行：
    python3 -m unittest tests.test_withdrawal_schedule -v
"""

import json
import os
import threading
import time
import unittest
import uuid
from datetime import datetime, timedelta, timezone

# 环境变量必须在导入 app.config 之前设置
os.environ.setdefault("SERVICE_KEY", "dev-service-key-change-me")
os.environ.setdefault(
    "REVIEW_CREDENTIALS",
    json.dumps(
        [
            {"username": "alice", "password": "alice-pw", "roles": ["operator"]},
            {"username": "bob", "password": "bob-pw", "roles": ["reviewer"]},
        ]
    ),
)

_PG_SERVER = None
_SKIP_REASON = ""
if "TEST_DATABASE_URL" not in os.environ:
    if "DATABASE_URL" not in os.environ:
        try:
            import pgserver

            _PG_SERVER = pgserver.get_server("/tmp/pgdata-withdrawal-schedule-test")
            os.environ["DATABASE_URL"] = (
                "postgresql+psycopg2://postgres@/postgres?host=/tmp/pgdata-withdrawal-schedule-test"
            )
        except Exception as exc:  # pragma: no cover - 环境不可用时跳过
            _PG_SERVER = None
            _SKIP_REASON = f"pgserver unavailable: {exc}"
    # 同进程其他测试模块已配置 DATABASE_URL（如 discover 全量运行）：
    # 直接复用同一数据库，不再另起实例、不覆盖既有配置
else:
    os.environ["DATABASE_URL"] = os.environ["TEST_DATABASE_URL"]

from fastapi.testclient import TestClient  # noqa: E402

from app import main as app_main  # noqa: E402

SKIP_INTEGRATION = "DATABASE_URL" not in os.environ

SERVICE_HEADERS = {"X-Service-Key": "dev-service-key-change-me"}
BASIC_ALICE = ("alice", "alice-pw")
BASIC_BOB = ("bob", "bob-pw")

TEXT_V1 = "患者张三，身份证号 110101199003077777，联系电话 13800001111。"
INTERVALS_V1 = [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat()


@unittest.skipIf(SKIP_INTEGRATION, _SKIP_REASON)
class WithdrawalScheduleIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app_main._init_db_with_retry()
        # 执行器高频运行，便于验证到点自动生效（lifespan 启动的后台线程按此周期扫描）
        app_main.settings.withdrawal_scheduler_interval_seconds = 0.2
        cls.client = TestClient(app_main.app)
        cls.client.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.client.__exit__(None, None, None)

    def setUp(self):
        # 每个用例使用全新记录，避免相互干扰
        r = self.client.post(
            "/records",
            headers=SERVICE_HEADERS,
            json={"text": TEXT_V1, "intervals": INTERVALS_V1},
        )
        self.assertEqual(r.status_code, 201, r.text)
        self.record_id = r.json()["record_id"]

    # ---- 工具方法 ----

    def _publish(self, record_id=None, **extra):
        body = {"version": 1}
        body.update(extra)
        r = self.client.post(
            f"/records/{record_id or self.record_id}/publish",
            headers=SERVICE_HEADERS,
            json=body,
        )
        self.assertEqual(r.status_code, 201, r.text)
        return r.json()

    def _schedule(self, snapshot_id, scheduled_at, reason="保留期届满，到期撤回", expected=201):
        r = self.client.post(
            f"/snapshots/{snapshot_id}/withdrawal-schedules",
            headers=SERVICE_HEADERS,
            json={"scheduled_at": scheduled_at, "reason": reason},
        )
        self.assertEqual(r.status_code, expected, r.text)
        return r

    def _future_iso(self, seconds=3600) -> str:
        return _iso(_utc_now() + timedelta(seconds=seconds))

    def _get_plan(self, schedule_id, expected=200):
        r = self.client.get(
            f"/withdrawal-schedules/{schedule_id}", headers=SERVICE_HEADERS
        )
        self.assertEqual(r.status_code, expected, r.text)
        return r

    def _cancel(self, schedule_id, expected=200):
        r = self.client.post(
            f"/withdrawal-schedules/{schedule_id}/cancel", headers=SERVICE_HEADERS
        )
        self.assertEqual(r.status_code, expected, r.text)
        return r

    def _snapshot_info(self, record_id=None, version=1):
        r = self.client.get(
            f"/records/{record_id or self.record_id}", headers=SERVICE_HEADERS
        )
        self.assertEqual(r.status_code, 200, r.text)
        for snap in r.json()["snapshots"]:
            if snap["version"] == version:
                return snap
        raise AssertionError(f"snapshot for version {version} not found")

    def _wait_plan_status(self, schedule_id, status, timeout=10.0):
        """轮询计划状态直至到达预期（供后台执行器相关断言使用）。"""
        deadline = time.monotonic() + timeout
        plan = None
        while time.monotonic() < deadline:
            plan = self._get_plan(schedule_id).json()
            if plan["status"] == status:
                return plan
            time.sleep(0.2)
        self.fail(f"plan {schedule_id} did not reach status {status!r}: {plan}")

    # ---- 提交计划：成功与响应内容 ----

    def test_create_schedule_returns_plan_and_is_queryable(self):
        pub = self._publish()
        sid, tok = pub["snapshot_id"], pub["token"]
        scheduled_at = _utc_now() + timedelta(seconds=3600)
        r = self._schedule(sid, _iso(scheduled_at), reason="保留期到 2026-11-01")
        body = r.json()
        # 返回计划编号、预定时刻与状态
        self.assertEqual(body["snapshot_id"], sid)
        self.assertEqual(body["status"], "scheduled")
        self.assertEqual(body["reason"], "保留期到 2026-11-01")
        self.assertFalse(body["replayed"])
        self.assertIsNone(body["executed_at"])
        self.assertIsNone(body["canceled_at"])
        self.assertIsNone(body["superseded_at"])
        # 预定时刻按绝对时刻回显（服务端统一为 UTC）
        self.assertEqual(
            datetime.fromisoformat(body["scheduled_at"]), scheduled_at
        )
        schedule_id = body["schedule_id"]
        # 按计划编号查询
        plan = self._get_plan(schedule_id).json()
        self.assertEqual(plan["schedule_id"], schedule_id)
        self.assertEqual(plan["status"], "scheduled")
        # 按快照列出计划
        r = self.client.get(
            f"/snapshots/{sid}/withdrawal-schedules", headers=SERVICE_HEADERS
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(
            [p["schedule_id"] for p in r.json()["schedules"]], [schedule_id]
        )
        # 计划未到时：公开读取不受影响
        r = self.client.get(f"/public/snapshots/{sid}?token={tok}")
        self.assertEqual(r.status_code, 200, r.text)
        # 快照维护状态仍为 published
        self.assertEqual(self._snapshot_info()["status"], "published")

    def test_schedule_requires_service_key(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        for headers in ({}, {"X-Service-Key": "wrong-key"}):
            r = self.client.post(
                f"/snapshots/{sid}/withdrawal-schedules",
                headers=headers,
                json={"scheduled_at": self._future_iso(), "reason": "x"},
            )
            self.assertEqual(r.status_code, 401, r.text)
        # 查询与取消同样需要密钥
        schedule_id = self._schedule(sid, self._future_iso()).json()["schedule_id"]
        self.assertEqual(
            self.client.get(f"/withdrawal-schedules/{schedule_id}").status_code, 401
        )
        self.assertEqual(
            self.client.get(f"/snapshots/{sid}/withdrawal-schedules").status_code, 401
        )
        self.assertEqual(
            self.client.post(f"/withdrawal-schedules/{schedule_id}/cancel").status_code,
            401,
        )

    def test_schedule_unknown_snapshot_404(self):
        r = self._schedule(uuid.uuid4(), self._future_iso(), expected=404)
        self.assertEqual(r.json()["detail"], "snapshot not found")
        # 查询/取消未知计划同样 404
        self._get_plan(uuid.uuid4(), expected=404)
        self._cancel(uuid.uuid4(), expected=404)
        # 列出未知快照的计划 404
        r = self.client.get(
            f"/snapshots/{uuid.uuid4()}/withdrawal-schedules", headers=SERVICE_HEADERS
        )
        self.assertEqual(r.status_code, 404, r.text)

    def test_schedule_withdrawn_snapshot_409(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        r = self.client.post(
            f"/snapshots/{sid}/withdraw",
            headers=SERVICE_HEADERS,
            json={"reason": "手动撤回"},
        )
        self.assertEqual(r.status_code, 200, r.text)
        # 已撤回快照不能再安排计划
        r = self._schedule(sid, self._future_iso(), expected=409)
        self.assertNotIn(TEXT_V1, r.text)

    def test_schedule_past_or_present_time_422(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        for at in (
            _iso(_utc_now() - timedelta(seconds=1)),
            _iso(_utc_now() - timedelta(days=30)),
        ):
            r = self._schedule(sid, at, expected=422)
            self.assertIn("scheduled_at", r.text)
        # 快照仍可读：422 不产生任何计划
        r = self.client.get(
            f"/snapshots/{sid}/withdrawal-schedules", headers=SERVICE_HEADERS
        )
        self.assertEqual(r.json()["schedules"], [])

    def test_schedule_blank_reason_422(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        for reason in ("", "   ", "\t\n"):
            r = self._schedule(sid, self._future_iso(), reason=reason, expected=422)
            self.assertIn("reason", r.text)
        # 缺少 reason 字段同样 422
        r = self.client.post(
            f"/snapshots/{sid}/withdrawal-schedules",
            headers=SERVICE_HEADERS,
            json={"scheduled_at": self._future_iso()},
        )
        self.assertEqual(r.status_code, 422, r.text)
        r = self.client.get(
            f"/snapshots/{sid}/withdrawal-schedules", headers=SERVICE_HEADERS
        )
        self.assertEqual(r.json()["schedules"], [])

    def test_schedule_naive_time_422(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        naive = (_utc_now() + timedelta(hours=1)).replace(tzinfo=None).isoformat()
        self.assertNotIn("+", naive)
        r = self._schedule(sid, naive, expected=422)
        self.assertIn("timezone", r.text)

    # ---- 同一快照只能有一个有效计划：幂等与冲突 ----

    def test_repeat_same_content_returns_original_plan(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        scheduled_at = _utc_now() + timedelta(seconds=3600)
        first = self._schedule(sid, _iso(scheduled_at), reason="相同内容").json()
        self.assertFalse(first["replayed"])
        # 完全相同内容（含同一绝对时刻的不同时区表达）重复提交 -> 200 原计划
        plus8 = scheduled_at.astimezone(timezone(timedelta(hours=8)))
        again = self._schedule(sid, _iso(plus8), reason="相同内容", expected=200).json()
        self.assertTrue(again["replayed"])
        self.assertEqual(again["schedule_id"], first["schedule_id"])
        self.assertEqual(again["scheduled_at"], first["scheduled_at"])
        # 仍只有一个计划
        r = self.client.get(
            f"/snapshots/{sid}/withdrawal-schedules", headers=SERVICE_HEADERS
        )
        self.assertEqual(len(r.json()["schedules"]), 1)

    def test_different_time_or_reason_requires_cancel_first(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        at = self._future_iso(3600)
        first = self._schedule(sid, at, reason="原计划").json()
        # 改原因 -> 409；改时间 -> 409
        self._schedule(sid, at, reason="别的原因", expected=409)
        self._schedule(sid, self._future_iso(7200), reason="原计划", expected=409)
        # 取消后即可重新安排（改时间/原因均可）
        self._cancel(first["schedule_id"])
        new_plan = self._schedule(sid, self._future_iso(7200), reason="新原因").json()
        self.assertFalse(new_plan["replayed"])
        self.assertNotEqual(new_plan["schedule_id"], first["schedule_id"])
        # 历史计划留存：canceled + scheduled 各一条
        r = self.client.get(
            f"/snapshots/{sid}/withdrawal-schedules", headers=SERVICE_HEADERS
        )
        self.assertEqual(
            [p["status"] for p in r.json()["schedules"]], ["canceled", "scheduled"]
        )

    def test_concurrent_identical_submissions_yield_single_plan(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        at = self._future_iso(3600)
        barrier = threading.Barrier(6)
        outcomes: list[dict] = []
        lock = threading.Lock()

        def submit():
            client = TestClient(app_main.app)
            barrier.wait()
            r = client.post(
                f"/snapshots/{sid}/withdrawal-schedules",
                headers=SERVICE_HEADERS,
                json={"scheduled_at": at, "reason": "并发相同内容"},
            )
            with lock:
                outcomes.append((r.status_code, r.json()))

        threads = [threading.Thread(target=submit) for _ in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        # 恰好一个首次创建（201），其余幂等返回原计划（200 replayed）
        codes = sorted(code for code, _ in outcomes)
        self.assertEqual(codes, [200, 200, 200, 200, 200, 201], outcomes)
        plan_ids = {body["schedule_id"] for _, body in outcomes}
        self.assertEqual(len(plan_ids), 1)
        replayed_flags = sorted(body["replayed"] for _, body in outcomes)
        self.assertEqual(replayed_flags, [False, True, True, True, True, True])
        r = self.client.get(
            f"/snapshots/{sid}/withdrawal-schedules", headers=SERVICE_HEADERS
        )
        self.assertEqual(len(r.json()["schedules"]), 1)

    # ---- 取消 ----

    def test_cancel_flow_and_idempotency(self):
        pub = self._publish(max_reads=2)
        sid, tok = pub["snapshot_id"], pub["token"]
        schedule_id = self._schedule(sid, self._future_iso()).json()["schedule_id"]
        # 生效前取消成功
        body = self._cancel(schedule_id).json()
        self.assertEqual(body["status"], "canceled")
        self.assertFalse(body["already_canceled"])
        self.assertIsNotNone(body["canceled_at"])
        # 重复取消幂等回放
        again = self._cancel(schedule_id).json()
        self.assertTrue(again["already_canceled"])
        self.assertEqual(again["status"], "canceled")
        self.assertEqual(again["canceled_at"], body["canceled_at"])
        # 取消后计划状态可查
        self.assertEqual(self._get_plan(schedule_id).json()["status"], "canceled")
        # 取消后公开读取不受影响（计划永不生效）
        r = self.client.get(f"/public/snapshots/{sid}?token={tok}")
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self._snapshot_info()["status"], "published")

    def test_cancel_after_effect_is_rejected_409(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        at = _iso(_utc_now() + timedelta(seconds=0.8))
        schedule_id = self._schedule(sid, at).json()["schedule_id"]
        # 等后台执行器把到点计划结算生效
        self._wait_plan_status(schedule_id, "executed")
        # 已生效计划的取消被明确拒绝
        r = self._cancel(schedule_id, expected=409)
        self.assertIn("already taken effect", r.text)
        # 计划状态保持 executed
        self.assertEqual(self._get_plan(schedule_id).json()["status"], "executed")

    def test_concurrent_cancels_are_idempotent(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        schedule_id = self._schedule(sid, self._future_iso()).json()["schedule_id"]
        barrier = threading.Barrier(6)
        outcomes: list[dict] = []
        lock = threading.Lock()

        def cancel():
            client = TestClient(app_main.app)
            barrier.wait()
            r = client.post(
                f"/withdrawal-schedules/{schedule_id}/cancel",
                headers=SERVICE_HEADERS,
            )
            with lock:
                outcomes.append((r.status_code, r.json()))

        threads = [threading.Thread(target=cancel) for _ in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        # 全部成功；恰好一个首次取消，其余幂等回放；取消时刻一致
        self.assertTrue(all(code == 200 for code, _ in outcomes), outcomes)
        flags = sorted(body["already_canceled"] for _, body in outcomes)
        self.assertEqual(flags, [False, True, True, True, True, True], outcomes)
        canceled_ats = {body["canceled_at"] for _, body in outcomes}
        self.assertEqual(len(canceled_ats), 1, outcomes)
        self.assertEqual(self._get_plan(schedule_id).json()["status"], "canceled")

    # ---- 到点生效：公开读取、计数与审计 ----

    def test_public_read_settles_due_schedule_without_consuming(self):
        # 暂停后台执行器：验证公开读取路径自身即可结算到点计划
        app_main._stop_withdrawal_scheduler()
        try:
            pub = self._publish(max_reads=3)
            sid, tok = pub["snapshot_id"], pub["token"]
            # 到点前成功读一次（消耗 1 次、写 1 条审计）
            r = self.client.get(f"/public/snapshots/{sid}?token={tok}")
            self.assertEqual(r.status_code, 200, r.text)
            at = _iso(_utc_now() + timedelta(seconds=0.8))
            schedule_id = self._schedule(sid, at, reason="计划原因A").json()[
                "schedule_id"
            ]
            time.sleep(1.0)  # 到点（执行器已停，尚未结算）
            self.assertEqual(
                self._get_plan(schedule_id).json()["status"], "scheduled"
            )
            # 到点后开始的公开读取：沿用既有模糊 403
            r = self.client.get(f"/public/snapshots/{sid}?token={tok}")
            self.assertEqual(r.status_code, 403)
            self.assertEqual(r.json()["detail"], "snapshot unavailable")
            self.assertNotIn("计划原因", r.text)
            # 无效令牌同样 403
            self.assertEqual(
                self.client.get(f"/public/snapshots/{sid}?token=bad").status_code, 403
            )
            # 读取路径完成了结算：计划生效、快照按计划时刻与原因撤回
            plan = self._get_plan(schedule_id).json()
            self.assertEqual(plan["status"], "executed")
            self.assertIsNotNone(plan["executed_at"])
            snap = self._snapshot_info()
            self.assertEqual(snap["status"], "withdrawn")
            self.assertEqual(snap["withdraw_reason"], "计划原因A")
            self.assertEqual(
                datetime.fromisoformat(snap["withdrawn_at"]),
                datetime.fromisoformat(at),
            )
            # 到点后的 403 不扣单令牌额度
            q = self.client.get(f"/tokens/{tok}", headers=SERVICE_HEADERS).json()
            self.assertEqual(q["reads_used"], 1)
            self.assertEqual(q["remaining_reads"], 2)
            # 不写成功读取审计：事件数仍为到点前的 1 条
            events = self.client.get(
                f"/snapshots/{sid}/read-events",
                headers=SERVICE_HEADERS,
                params={"start": "2000-01-01T00:00:00Z", "end": "2100-01-01T00:00:00Z"},
            ).json()
            self.assertEqual(len(events["events"]), 1)
        finally:
            app_main._start_withdrawal_scheduler()

    def test_scheduler_executes_due_plan_without_traffic(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        at = _iso(_utc_now() + timedelta(seconds=0.8))
        schedule_id = self._schedule(sid, at, reason="执行器原因").json()["schedule_id"]
        # 不发起任何请求：后台执行器应在到点后自动结算
        plan = self._wait_plan_status(schedule_id, "executed")
        self.assertIsNotNone(plan["executed_at"])
        snap = self._snapshot_info()
        self.assertEqual(snap["status"], "withdrawn")
        self.assertEqual(snap["withdraw_reason"], "执行器原因")
        # 撤回时刻为计划预定时刻
        self.assertEqual(
            datetime.fromisoformat(snap["withdrawn_at"]), datetime.fromisoformat(at)
        )

    def test_restart_does_not_miss_due_execution(self):
        # 模拟服务停止期间计划到点：停止后台执行器，让计划到点
        app_main._stop_withdrawal_scheduler()
        try:
            pub = self._publish()
            sid = pub["snapshot_id"]
            at = _iso(_utc_now() + timedelta(seconds=0.8))
            schedule_id = self._schedule(sid, at).json()["schedule_id"]
            time.sleep(1.0)  # 到点，但执行器已停：计划仍未生效
            self.assertEqual(
                self._get_plan(schedule_id).json()["status"], "scheduled"
            )
        finally:
            # 模拟服务重启：执行器恢复后立即补执行到点计划
            app_main._start_withdrawal_scheduler()
        self._wait_plan_status(schedule_id, "executed")
        self.assertEqual(self._snapshot_info()["status"], "withdrawn")

    def test_due_schedule_blocks_republish(self):
        # 暂停执行器：验证发布路径自身也会结算到点计划并拒绝重新公开
        app_main._stop_withdrawal_scheduler()
        try:
            pub = self._publish()
            sid = pub["snapshot_id"]
            at = _iso(_utc_now() + timedelta(seconds=0.8))
            schedule_id = self._schedule(sid, at).json()["schedule_id"]
            time.sleep(1.0)
            r = self.client.post(
                f"/records/{self.record_id}/publish",
                headers=SERVICE_HEADERS,
                json={"version": 1},
            )
            self.assertEqual(r.status_code, 409, r.text)
            # 发布路径完成了结算
            self.assertEqual(self._get_plan(schedule_id).json()["status"], "executed")
            self.assertEqual(self._snapshot_info()["status"], "withdrawn")
        finally:
            app_main._start_withdrawal_scheduler()

    # ---- 与手动撤回的交互 ----

    def test_manual_withdraw_first_supersedes_schedule(self):
        pub = self._publish()
        sid = pub["snapshot_id"]
        schedule_id = self._schedule(
            sid, self._future_iso(3600), reason="计划原因"
        ).json()["schedule_id"]
        # 手动撤回先发生：以手动撤回时间和原因为准
        r = self.client.post(
            f"/snapshots/{sid}/withdraw",
            headers=SERVICE_HEADERS,
            json={"reason": "手动原因"},
        )
        self.assertEqual(r.status_code, 200, r.text)
        manual_at = r.json()["withdrawn_at"]
        # 计划终止（superseded）
        plan = self._get_plan(schedule_id).json()
        self.assertEqual(plan["status"], "superseded")
        self.assertIsNotNone(plan["superseded_at"])
        # 快照以手动撤回的时间与原因为准
        snap = self._snapshot_info()
        self.assertEqual(snap["withdraw_reason"], "手动原因")
        self.assertEqual(snap["withdrawn_at"], manual_at)
        # 已被取代的计划再取消：幂等回放（不是 409）
        again = self._cancel(schedule_id).json()
        self.assertTrue(again["already_canceled"])
        self.assertEqual(again["status"], "superseded")
        # 计划预定时刻过后也不会再生效（状态保持 superseded）
        time.sleep(0.5)
        self.assertEqual(self._get_plan(schedule_id).json()["status"], "superseded")

    def test_manual_withdraw_after_due_replays_schedule_result(self):
        # 暂停执行器：计划先到时但未结算，手动撤回应回放计划的首次结果
        app_main._stop_withdrawal_scheduler()
        try:
            pub = self._publish()
            sid = pub["snapshot_id"]
            at = _iso(_utc_now() + timedelta(seconds=0.8))
            schedule_id = self._schedule(sid, at, reason="计划原因B").json()[
                "schedule_id"
            ]
            time.sleep(1.0)  # 到点（执行器已停，计划仍 scheduled）
            # 计划先到时：手动撤回回放首次结果，不能改写原因
            r = self.client.post(
                f"/snapshots/{sid}/withdraw",
                headers=SERVICE_HEADERS,
                json={"reason": "试图改写的手动原因"},
            )
            self.assertEqual(r.status_code, 200, r.text)
            body = r.json()
            self.assertEqual(body["status"], "withdrawn")
            # 撤回时刻为计划预定时刻，而非手动撤回时刻
            self.assertEqual(
                datetime.fromisoformat(body["withdrawn_at"]),
                datetime.fromisoformat(at),
            )
            # 手动撤回触发了结算：计划生效，原因未被改写
            self.assertEqual(self._get_plan(schedule_id).json()["status"], "executed")
            snap = self._snapshot_info()
            self.assertEqual(snap["withdraw_reason"], "计划原因B")
            self.assertEqual(snap["withdrawn_at"], body["withdrawn_at"])
        finally:
            app_main._start_withdrawal_scheduler()

    def test_manual_withdraw_after_execution_replays_first_result(self):
        # 执行器先把计划结算生效，随后的手动撤回同样回放首次结果
        pub = self._publish()
        sid = pub["snapshot_id"]
        at = _iso(_utc_now() + timedelta(seconds=0.8))
        schedule_id = self._schedule(sid, at, reason="计划原因C").json()["schedule_id"]
        self._wait_plan_status(schedule_id, "executed")
        r = self.client.post(
            f"/snapshots/{sid}/withdraw",
            headers=SERVICE_HEADERS,
            json={"reason": "事后手动原因"},
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(
            datetime.fromisoformat(r.json()["withdrawn_at"]),
            datetime.fromisoformat(at),
        )
        self.assertEqual(self._snapshot_info()["withdraw_reason"], "计划原因C")

    # ---- 共享凭证：清单内其他快照不受影响 ----

    def test_bundle_reads_unaffected_for_other_snapshots(self):
        pub1 = self._publish()
        sid1 = pub1["snapshot_id"]
        # 第二条记录的第二个快照
        r = self.client.post(
            "/records",
            headers=SERVICE_HEADERS,
            json={"text": TEXT_V1, "intervals": INTERVALS_V1},
        )
        record2 = r.json()["record_id"]
        pub2 = self._publish(record_id=record2)
        sid2 = pub2["snapshot_id"]
        # 共享凭证：两个快照共用额度 5
        r = self.client.post(
            "/bundle-requests",
            auth=BASIC_ALICE,
            json={"snapshot_ids": [sid1, sid2], "max_reads": 5},
        )
        self.assertEqual(r.status_code, 201, r.text)
        brid = r.json()["request_id"]
        r = self.client.post(f"/bundle-requests/{brid}/approve", auth=BASIC_BOB)
        self.assertEqual(r.status_code, 200, r.text)
        cred = r.json()["credential"]
        bundle_id = r.json()["bundle_id"]
        # 两个快照各成功读一次（共享额度已用 2）
        self.assertEqual(
            self.client.get(f"/public/snapshots/{sid1}?token={cred}").status_code, 200
        )
        self.assertEqual(
            self.client.get(f"/public/snapshots/{sid2}?token={cred}").status_code, 200
        )
        # 安排 sid1 的计划撤回并等到生效
        at = _iso(_utc_now() + timedelta(seconds=0.8))
        schedule_id = self._schedule(sid1, at, reason="清单内单项到期").json()[
            "schedule_id"
        ]
        self._wait_plan_status(schedule_id, "executed")
        # sid1 到点后 403 且不扣共享额度；sid2 不受影响继续可读
        r = self.client.get(f"/public/snapshots/{sid1}?token={cred}")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"], "snapshot unavailable")
        r = self.client.get(f"/public/snapshots/{sid2}?token={cred}")
        self.assertEqual(r.status_code, 200, r.text)
        bundle = self.client.get(
            f"/read-bundles/{bundle_id}", headers=SERVICE_HEADERS
        ).json()
        # 共享额度只被成功读取消耗（2 次到点前 + 1 次 sid2 到点后）
        self.assertEqual(bundle["reads_used"], 3)
        self.assertEqual(bundle["remaining_reads"], 2)
        items = {item["snapshot_id"]: item["status"] for item in bundle["items"]}
        self.assertEqual(items[sid1], "withdrawn")
        self.assertEqual(items[sid2], "published")

    # ---- 多实例并发结算：恰好一个生效 ----

    def test_concurrent_settlement_is_idempotent_across_instances(self):
        # 暂停后台执行器，手动并发调用两轮“执行器扫描”模拟多实例同时补执行
        app_main._stop_withdrawal_scheduler()
        try:
            pub = self._publish()
            sid = pub["snapshot_id"]
            at = _iso(_utc_now() + timedelta(seconds=0.5))
            schedule_id = self._schedule(sid, at, reason="并发结算").json()[
                "schedule_id"
            ]
            time.sleep(0.8)
            barrier = threading.Barrier(4)
            results: list[int] = []
            lock = threading.Lock()

            def sweep():
                barrier.wait()
                settled = app_main._settle_due_schedules_once()
                with lock:
                    results.append(settled)

            threads = [threading.Thread(target=sweep) for _ in range(4)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            # 4 个“实例”同时扫描：恰好一个结算了该计划，其余为 0
            self.assertEqual(sorted(results), [0, 0, 0, 1], results)
            # 再次扫描：无到点计划，幂等
            self.assertEqual(app_main._settle_due_schedules_once(), 0)
            self.assertEqual(self._get_plan(schedule_id).json()["status"], "executed")
            snap = self._snapshot_info()
            self.assertEqual(snap["status"], "withdrawn")
            self.assertEqual(snap["withdraw_reason"], "并发结算")
        finally:
            app_main._start_withdrawal_scheduler()


if __name__ == "__main__":
    unittest.main()
