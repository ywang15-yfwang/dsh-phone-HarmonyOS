/**
 * 权限查询/切换（host 半边）。
 * 只动**当前会话**：`permissionPresets.set(session, preset)`。
 */
export function createPermissionApi(ctx) {
  function sessionOf(sessionId) {
    try {
      const agents = ctx.get === undefined ? undefined : ctx.get("agents");
      const agent = agents === null || agents === undefined ? undefined : agents.get(sessionId);
      return agent === null || agent === undefined ? undefined : agent.session;
    } catch (error) {
      return undefined;
    }
  }

  function presetsOf() {
    try {
      return ctx.get === undefined ? undefined : ctx.get("permissionPresets");
    } catch (error) {
      return undefined;
    }
  }

  function state(sessionId) {
    const presets = presetsOf();
    const session = sessionOf(sessionId);
    if (presets === undefined || session === undefined) {
      return { ok: false, error: "no-session" };
    }
    try {
      const catalog = presets.catalog();
      const options = Array.isArray(catalog.options)
        ? catalog.options.filter((one) => one !== null && one.value !== "custom")
        : [];
      return {
        ok: true,
        sessionId,
        current: presets.current(session),
        options,
        defaultPreset: catalog.defaultPreset
      };
    } catch (error) {
      return { ok: false, error: "permission-unavailable" };
    }
  }

  function set(sessionId, value) {
    const presets = presetsOf();
    const session = sessionOf(sessionId);
    if (presets === undefined || session === undefined) {
      return { ok: false, error: "no-session" };
    }
    try {
      const catalog = presets.catalog();
      const options = Array.isArray(catalog.options) ? catalog.options : [];
      const allowed = options.some((one) => one !== null && one.value === value && one.value !== "custom");
      if (!allowed) return { ok: false, error: "bad-preset" };
      presets.set(session, value);
      return state(sessionId);
    } catch (error) {
      return { ok: false, error: "permission-set-failed" };
    }
  }

  return { state, set };
}
