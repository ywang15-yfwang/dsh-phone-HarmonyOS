// napi_init.cpp —— 把 Go 内核（libtailscale_go.so 的 C ABI）包成 ArkTS 能 import 的 NAPI 模块。
//
// 命名与调用形态沿用已跑通的参考实现 _refs\Tailscale-OHOS\entry\src\main\cpp\napi_init.cpp
// （flypigJ/Tailscale-OHOS@fd49406f），**按本项目范围裁剪**：
// 只保留成为 tailnet 节点所需的接口。参考实现里的 Taildrop（收发文件）/ Taildrive
// （WebDAV 文件共享）/ 媒体探测 / exit node / 网络开关 **一律不导出** ——
// 对应 N3（不做远程桌面）、N11（不做第三方服务集成）、N12（不做 tailnet 运维台），
// 以及 F14：手机侧不得存在"由远端触发动作"的通路，Taildrop 收件正是这样一条通路。
//
// 所有返回值都是 **JSON 字符串**（TSHello / probeEngine / controlProbe 除外），
// 由 ArkTS 侧 JSON.parse；这样比解析分隔符字符串稳。

#include "napi/native_api.h"
#include "hilog/log.h"
#include "libtailscale_go.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------- F14 闸门（导出面 = 手机侧对外的全部能力面）
//
// F14「手机侧不被反向操作」在本文件上有三条硬性要求，改动前先读这里：
//   1. **不提供任何"供远端接入"的入口** —— 本模块不得出现监听 / 接收 / 服务端语义的导出
//      （监听端口、收件、被推送）。参考实现的 Taildrop 收件监听正是一条这样的通路，已按范围去掉。
//   2. **只有"拉"，没有"推"** —— 本文件**从不**使用 `napi_create_threadsafe_function` /
//      `napi_call_function` 之类的回调机制，也没有事件订阅入口：
//      ArkTS 只能主动调用、拿返回值，**内核无法主动让 ArkTS 去做什么**。
//      （新增任何"回调注册"形态的导出，等于开一条"由远端内容触发本地动作"的路，属 F14 违规。）
//   3. **导出面逐个点名** —— 新增导出必须显式改下面的 `kExportTotal`，并与
//      `harmonyos-app-toolchain\build-kernel-bridge.ps1` 的「导出面双向核对」
//      （.so 的 TS* 导出 ≤ NAPI 面，多一个就构建失败）一起过。
//
// 为什么要一个编译期数字：光靠"人记得别加"是不可查的；有了这个 static_assert，
// 任何新增导出都会**立刻编译不过**，逼改动者回到这里说明它为什么符合 F14。
constexpr std::size_t kExportTotal = 25;

// ---------------------------------------------------------------- 通用工具

napi_value NullValue(napi_env env)
{
    napi_value result = nullptr;
    napi_get_null(env, &result);
    return result;
}

// 把 Go 侧返回的 C 字符串转成 napi string，并**立刻释放**它。
// Go 侧约定：每个返回 char* 的导出都必须由调用方用 TSFreeString 释放。
napi_value StringResult(napi_env env, char* message, const char* failureMessage)
{
    if (message == nullptr) {
        napi_throw_error(env, nullptr, failureMessage);
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, failureMessage);
        return nullptr;
    }
    return result;
}

// 读取一个 UTF-8 字符串参数；不是字符串就抛类型错并返回 false。
bool ReadStringArg(napi_env env, napi_value value, const char* name, std::string& out)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        std::string message = std::string(name) + " must be a string";
        napi_throw_type_error(env, nullptr, message.c_str());
        return false;
    }
    std::vector<char> buffer(length + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length) != napi_ok) {
        std::string message = std::string("Failed to read ") + name;
        napi_throw_error(env, nullptr, message.c_str());
        return false;
    }
    out.assign(buffer.data(), length);
    return true;
}

// ---------------------------------------------------------------- 异步（工作线程）

// 内核调用会阻塞（tsnet 启动、状态查询、控制平面探测都可能等网络），
// 所以**每个可能阻塞的入口都提供异步形态**，别让 ArkTS 的 UI 线程被卡住。
// 另外：鸿蒙侧 startVpnExtensionAbility 失败时 Promise 不会 settle，
// 调用方要配 backendStatus 轮询兜底 —— backendStatus 是**同步**返回的，正是为此。
struct AsyncCallWork {
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    std::function<std::string()> call;
    std::string result;
    bool succeeded = false;
};

void ExecuteAsyncCall(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<AsyncCallWork*>(data);
    try {
        work->result = work->call();
        work->succeeded = true;
    } catch (...) {
        work->succeeded = false;
    }
}

void CompleteAsyncCall(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<AsyncCallWork*>(data);
    napi_value value = nullptr;
    if (status == napi_ok && work->succeeded &&
        napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message = nullptr;
        napi_value error = nullptr;
        napi_create_string_utf8(env, "Native backend call failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value CreateAsyncCallPromise(
    napi_env env, std::function<std::string()> call, const char* resourceName)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create native promise");
        return nullptr;
    }
    auto* work = new AsyncCallWork();
    work->deferred = deferred;
    work->call = std::move(call);

    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteAsyncCall, CompleteAsyncCall,
            work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue native call");
        return nullptr;
    }
    return promise;
}

// 无参导出统一走这里：同步形态 + 异步形态共用同一个函数指针。
using NativeStringFunction = char* (*)();

napi_value CallSync(napi_env env, NativeStringFunction function, const char* failure)
{
    return StringResult(env, function(), failure);
}

napi_value CallAsync(
    napi_env env, NativeStringFunction function, const char* resourceName)
{
    return CreateAsyncCallPromise(env, [function]() -> std::string {
        char* message = function();
        if (message == nullptr) {
            // 与同步形态保持一致：null 是失败，不能当"空结果"resolve（否则上层把错误当空数据）
            throw std::runtime_error("native call returned null");
        }
        std::string result(message);
        TSFreeString(message);
        return result;
    }, resourceName);
}

// ---------------------------------------------------------------- 存活 / 引擎探针

napi_value Hello(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSHello, "hello returned a null status");
}

napi_value ProbeEngine(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSProbeEngine, "probeEngine returned a null status");
}

napi_value ProbeEngineAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallAsync(env, TSProbeEngine, "TailscaleProbeEngine");
}

napi_value TailscaleVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSTailscaleVersion, "tailscaleVersion returned a null status");
}

napi_value ControlProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSControlProbe, "controlProbe returned a null status");
}

napi_value ControlProbeAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallAsync(env, TSControlProbe, "TailscaleControlProbe");
}

// ---------------------------------------------------------------- 状态 / 授权 URL / peer

napi_value BackendStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSBackendStatus, "backendStatus returned a null status");
}

napi_value BackendAuthURL(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSBackendAuthURL, "backendAuthURL returned a null status");
}

napi_value BackendAuthURLAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallAsync(env, TSBackendAuthURL, "TailscaleBackendAuthURL");
}

napi_value BackendPeers(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSBackendPeers, "backendPeers returned a null status");
}

napi_value BackendPeersAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallAsync(env, TSBackendPeers, "TailscaleBackendPeers");
}

napi_value BackendStop(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSBackendStop, "backendStop returned a null status");
}

napi_value BackendStopAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallAsync(env, TSBackendStop, "TailscaleBackendStop");
}

napi_value BackendLogout(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSync(env, TSBackendLogout, "backendLogout returned a null status");
}

napi_value BackendLogoutAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallAsync(env, TSBackendLogout, "TailscaleBackendLogout");
}

// ---------------------------------------------------------------- 启动（带参）

// 读取 (stateDir, deviceModel, osVersion, controlURL)，可选再读一个 int32 fd。
bool ReadStartArgs(
    napi_env env, napi_callback_info info, bool withDescriptor,
    std::string& stateDir, std::string& deviceModel, std::string& osVersion,
    std::string& controlURL, int32_t& fd)
{
    size_t argc = withDescriptor ? 5 : 4;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != static_cast<size_t>(withDescriptor ? 5 : 4)) {
        napi_throw_type_error(env, nullptr, withDescriptor
            ? "requires stateDir, deviceModel, osVersion, controlURL and tunFd"
            : "requires stateDir, deviceModel, osVersion and controlURL");
        return false;
    }
    if (!ReadStringArg(env, args[0], "stateDir", stateDir) ||
        !ReadStringArg(env, args[1], "deviceModel", deviceModel) ||
        !ReadStringArg(env, args[2], "osVersion", osVersion) ||
        !ReadStringArg(env, args[3], "controlURL", controlURL)) {
        return false;
    }
    fd = -1;
    if (withDescriptor && napi_get_value_int32(env, args[4], &fd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "tunFd must be an integer");
        return false;
    }
    return true;
}

napi_value BackendStart(napi_env env, napi_callback_info info)
{
    std::string stateDir, deviceModel, osVersion, controlURL;
    int32_t fd = -1;
    if (!ReadStartArgs(env, info, false, stateDir, deviceModel, osVersion, controlURL, fd)) {
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "Tailscale OHOS: backendStart");
    return StringResult(env,
        TSBackendStart(const_cast<char*>(stateDir.c_str()), const_cast<char*>(deviceModel.c_str()),
            const_cast<char*>(osVersion.c_str()), const_cast<char*>(controlURL.c_str())),
        "backendStart returned a null status");
}

napi_value BackendStartAsync(napi_env env, napi_callback_info info)
{
    std::string stateDir, deviceModel, osVersion, controlURL;
    int32_t fd = -1;
    if (!ReadStartArgs(env, info, false, stateDir, deviceModel, osVersion, controlURL, fd)) {
        return nullptr;
    }
    return CreateAsyncCallPromise(env, [stateDir, deviceModel, osVersion, controlURL]() -> std::string {
        char* message = TSBackendStart(const_cast<char*>(stateDir.c_str()),
            const_cast<char*>(deviceModel.c_str()), const_cast<char*>(osVersion.c_str()),
            const_cast<char*>(controlURL.c_str()));
        if (message == nullptr) {
            return std::string();
        }
        std::string result(message);
        TSFreeString(message);
        return result;
    }, "TailscaleBackendStart");
}

napi_value BackendRestartWithTun(napi_env env, napi_callback_info info)
{
    std::string stateDir, deviceModel, osVersion, controlURL;
    int32_t fd = -1;
    if (!ReadStartArgs(env, info, true, stateDir, deviceModel, osVersion, controlURL, fd)) {
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "Tailscale OHOS: backendRestartWithTun");
    return StringResult(env,
        TSBackendRestartWithTun(const_cast<char*>(stateDir.c_str()),
            const_cast<char*>(deviceModel.c_str()), const_cast<char*>(osVersion.c_str()),
            const_cast<char*>(controlURL.c_str()), fd),
        "backendRestartWithTun returned a null status");
}

napi_value BackendRestartWithTunAsync(napi_env env, napi_callback_info info)
{
    std::string stateDir, deviceModel, osVersion, controlURL;
    int32_t fd = -1;
    if (!ReadStartArgs(env, info, true, stateDir, deviceModel, osVersion, controlURL, fd)) {
        return nullptr;
    }
    return CreateAsyncCallPromise(env,
        [stateDir, deviceModel, osVersion, controlURL, fd]() -> std::string {
            char* message = TSBackendRestartWithTun(const_cast<char*>(stateDir.c_str()),
                const_cast<char*>(deviceModel.c_str()), const_cast<char*>(osVersion.c_str()),
                const_cast<char*>(controlURL.c_str()), fd);
            if (message == nullptr) {
                return std::string();
            }
            std::string result(message);
            TSFreeString(message);
            return result;
        }, "TailscaleBackendRestartWithTun");
}

// ---------------------------------------------------------------- TUN fd 探针

napi_value TunFdProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "tunFdProbe requires one integer descriptor");
        return nullptr;
    }
    int32_t fd = -1;
    if (napi_get_value_int32(env, args[0], &fd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "TUN descriptor must be an integer");
        return nullptr;
    }
    return StringResult(env, TSTunFDProbe(fd), "tunFdProbe returned a null status");
}

// ---------------------------------------------------------------- 经内核 netstack 的流式请求（A 路）
//
// 契约：harmonyos-app-toolchain\docs\p2-kernel-request-export-contract-draft.md
// **5 个全部非阻塞**（拉模型）⇒ **刻意不提供 …Async 变体**：它们本来就不等。
// **这 5 个只允许扩展进程调用** —— UI 进程调会在 UI 进程里起一个独立内核（接口文档 §0.1 不变量 1/2）。

napi_value PeerRequestOpen(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendPeerRequestOpen requires one request JSON string");
        return nullptr;
    }
    std::string request;
    if (!ReadStringArg(env, args[0], "requestJson", request)) {
        return nullptr;
    }
    return StringResult(env,
        TSBackendPeerRequestOpen(const_cast<char*>(request.c_str())),
        "backendPeerRequestOpen returned a null status");
}

napi_value PeerRequestWrite(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendPeerRequestWrite requires a handle and a base64 chunk");
        return nullptr;
    }
    double handle = 0;
    if (napi_get_value_double(env, args[0], &handle) != napi_ok) {
        napi_throw_type_error(env, nullptr, "handle must be a number");
        return nullptr;
    }
    std::string chunk;
    if (!ReadStringArg(env, args[1], "chunkBase64", chunk)) {
        return nullptr;
    }
    return StringResult(env,
        TSBackendPeerRequestWrite(static_cast<unsigned long long>(handle), const_cast<char*>(chunk.c_str())),
        "backendPeerRequestWrite returned a null status");
}

napi_value PeerRequestFinish(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendPeerRequestFinish requires one handle");
        return nullptr;
    }
    double handle = 0;
    if (napi_get_value_double(env, args[0], &handle) != napi_ok) {
        napi_throw_type_error(env, nullptr, "handle must be a number");
        return nullptr;
    }
    return StringResult(env,
        TSBackendPeerRequestFinish(static_cast<unsigned long long>(handle)),
        "backendPeerRequestFinish returned a null status");
}

napi_value PeerRequestRead(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendPeerRequestRead requires a handle and a max byte count");
        return nullptr;
    }
    double handle = 0;
    if (napi_get_value_double(env, args[0], &handle) != napi_ok) {
        napi_throw_type_error(env, nullptr, "handle must be a number");
        return nullptr;
    }
    int32_t maxBytes = 0;
    if (napi_get_value_int32(env, args[1], &maxBytes) != napi_ok) {
        napi_throw_type_error(env, nullptr, "maxBytes must be an integer");
        return nullptr;
    }
    return StringResult(env,
        TSBackendPeerRequestRead(static_cast<unsigned long long>(handle), maxBytes),
        "backendPeerRequestRead returned a null status");
}

napi_value PeerRequestClose(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendPeerRequestClose requires one handle");
        return nullptr;
    }
    double handle = 0;
    if (napi_get_value_double(env, args[0], &handle) != napi_ok) {
        napi_throw_type_error(env, nullptr, "handle must be a number");
        return nullptr;
    }
    return StringResult(env,
        TSBackendPeerRequestClose(static_cast<unsigned long long>(handle)),
        "backendPeerRequestClose returned a null status");
}

} // namespace

// ---------------------------------------------------------------- 模块注册

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"hello", nullptr, Hello, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeEngine", nullptr, ProbeEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeEngineAsync", nullptr, ProbeEngineAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tailscaleVersion", nullptr, TailscaleVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"controlProbe", nullptr, ControlProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"controlProbeAsync", nullptr, ControlProbeAsync, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"backendStart", nullptr, BackendStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStartAsync", nullptr, BackendStartAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendRestartWithTun", nullptr, BackendRestartWithTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendRestartWithTunAsync", nullptr, BackendRestartWithTunAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendStop", nullptr, BackendStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStopAsync", nullptr, BackendStopAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLogout", nullptr, BackendLogout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLogoutAsync", nullptr, BackendLogoutAsync, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"backendStatus", nullptr, BackendStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAuthURL", nullptr, BackendAuthURL, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAuthURLAsync", nullptr, BackendAuthURLAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeers", nullptr, BackendPeers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeersAsync", nullptr, BackendPeersAsync, nullptr, nullptr, nullptr, napi_default, nullptr},

        {"tunFdProbe", nullptr, TunFdProbe, nullptr, nullptr, nullptr, napi_default, nullptr},

        // A 路：经内核 netstack 的流式请求（5 个，全部非阻塞 ⇒ 无 …Async 变体）
        {"backendPeerRequestOpen", nullptr, PeerRequestOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerRequestWrite", nullptr, PeerRequestWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerRequestFinish", nullptr, PeerRequestFinish, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerRequestRead", nullptr, PeerRequestRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerRequestClose", nullptr, PeerRequestClose, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    // F14 闸门：导出面变了就编译不过（改完记得同步 kExportTotal 的说明与构建脚本的核对）。
    static_assert(sizeof(descriptors) / sizeof(descriptors[0]) == kExportTotal,
        "F14: NAPI export surface changed -- update kExportTotal deliberately");
    napi_status status = napi_define_properties(
        env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to register the Tailscale OHOS native exports");
    }
    return exports;
}
EXTERN_C_END

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    // 与参考实现保持一致：OHOS 把 `libtailscale_ohos.so` 这个 import 名去掉
    // "lib" 前缀与 ".so" 后缀后拿来匹配 nm_modname，所以这里是 "tailscale_ohos"。
    .nm_modname = "tailscale_ohos",
    .nm_priv = nullptr,
    .reserved = {0}
};

extern "C" __attribute__((constructor)) void RegisterTailscaleOhosModule()
{
    napi_module_register(&module);
}
