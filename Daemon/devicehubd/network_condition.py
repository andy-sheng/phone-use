"""Device-wide Network Link conditioning over the selected device's Instruments connection."""
import asyncio
from contextlib import AsyncExitStack

from pymobiledevice3.services.dvt.instruments.condition_inducer import ConditionInducer
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider

from devicehubd.protocol import RpcError


class NetworkCondition:
    def __init__(self, rsd):
        self.rsd = rsd
        self.lock = asyncio.Lock()
        self.stack = AsyncExitStack()
        self.service = None
        self.owned_profile = None

    async def close(self):
        async with self.lock:
            await self._release()

    async def _release(self):
        # Instruments ties the condition to this connection. Closing it also works if
        # the worker exits unexpectedly, without clearing another client's condition.
        self.owned_profile = None
        self.service = None
        await self.stack.aclose()

    async def _connect(self, stack):
        provider = await stack.enter_async_context(DvtProvider(self.rsd))
        return await stack.enter_async_context(ConditionInducer(provider))

    async def _snapshot(self, service):
        groups = await service.list()
        group = next((item for item in groups if item["identifier"] == "SlowNetworkCondition"), None)
        if group is None:
            raise RpcError("unsupported", "此设备未提供 Network Link 弱网模拟")
        profiles = [{"id": p["identifier"], "name": p["name"], "detail": p.get("description", "")}
                    for p in group.get("profiles", [])]
        active = group.get("activeProfile") or None
        if isinstance(active, dict):
            active = active.get("identifier")
        return {"profiles": profiles, "activeProfile": active,
                "owned": bool(group.get("isActive") and active and active == self.owned_profile),
                "inUse": any(g.get("isActive") for g in groups)}

    async def command(self, method, params):
        async with self.lock:
            try:
                async with asyncio.timeout(20), AsyncExitStack() as temporary:
                    service = self.service
                    if service is None:
                        service = await self._connect(temporary)
                    state = await self._snapshot(service)
                    if self.service and not state["owned"]:
                        # The phone can end a condition itself. Reconcile our lease.
                        await self._release()
                        if method != "networkCondition":
                            raise RpcError("conditionChanged", "设备状态已改变，请刷新后重试")
                    if method == "enableNetworkCondition":
                        profile = params.get("profile")
                        if profile not in [p["id"] for p in state["profiles"]]:
                            raise RpcError("invalidParams", "此设备未提供所选网络档位")
                        if state["owned"] and state["activeProfile"] == profile:
                            return state
                        if state["inUse"]:
                            raise RpcError("conditionInUse", "请先结束设备上正在运行的模拟条件")
                        await service.set(profile)
                        self.owned_profile = profile
                        self.service = service
                        self.stack = temporary.pop_all()
                        state = await self._snapshot(service)
                        if not state["owned"]:
                            await self._release()
                            raise RpcError("conditionFailed", "设备未确认启用所选弱网档位")
                    elif method == "disableNetworkCondition" and state["owned"]:
                        # Never issue disableActiveCondition: it is global and could
                        # stop a condition Xcode enabled just after our status read.
                        await self._release()
                        observer = await self._connect(temporary)
                        state = await self._snapshot(observer)
                    return state
            except RpcError:
                raise
            except Exception:
                await self._release()
                raise
