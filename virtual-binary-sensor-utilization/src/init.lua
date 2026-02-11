local MatterDriver           = require "st.matter.driver"
local capabilities           = require "st.capabilities"

local cycleCap               = capabilities["signalprogram56169.cycleState"]

local clusters               = require "st.matter.clusters"
local BooleanState           = clusters.BooleanState
local PowerSource            = clusters.PowerSource

-- =========================
-- Tunáveis
-- =========================
local DEBOUNCE_SECONDS       = 20  -- você já usa
local STARTED_GRACE_SECONDS  = 120 -- X: tempo em uso antes de virar "running"
local COMPLETED_HOLD_SECONDS = 300 -- 5 min segurando "completed"

local MIN_RUNTIME_SECONDS    = 300 -- você já usa (5 min)
local END_GAP_SECONDS        = 480 -- você já usa (8 min)

local function now_seconds()
  return os.time()
end

-- =========================
-- Timers helpers
-- =========================
local function set_timer(device, field_name, seconds, fn)
  local old = device:get_field(field_name)
  if old then
    device.thread:cancel_timer(old)
  end
  local ref = device.thread:call_with_delay(seconds, fn)
  device:set_field(field_name, ref, { persist = false })
end

local function clear_timer(device, field_name)
  local old = device:get_field(field_name)
  if old then
    device.thread:cancel_timer(old)
    device:set_field(field_name, nil, { persist = false })
  end
end

-- =========================
-- Utilization
-- =========================
local function emit_utilization(device, in_use)
  local status = in_use and "inUse" or "notInUse"
  device:emit_event(capabilities.applianceUtilization.status(status, { state_change = true }))
end

-- =========================
-- Cycle State helpers
-- =========================
local function get_cycle_state(device)
  return device:get_field("cycle_state") or "idle"
end

local function set_cycle_state(device, state)
  if get_cycle_state(device) == state then return end
  device:set_field("cycle_state", state, { persist = false })
  device:emit_event(cycleCap.cycleState(state, { state_change = true }))
end

-- =========================
-- Runtime tracking
-- =========================
local function start_running(device)
  if not device:get_field("run_started_at") then
    device:set_field("run_started_at", now_seconds(), { persist = false })
  end
end

local function stop_running_and_accumulate(device)
  local started = device:get_field("run_started_at")
  if not started then
    -- mesmo assim marca stop pra janela de gap funcionar
    device:set_field("last_stop_at", now_seconds(), { persist = false })
    return
  end

  local acc = device:get_field("run_accumulated_s") or 0
  local dur = now_seconds() - started
  if dur < 0 then dur = 0 end

  device:set_field("run_accumulated_s", acc + dur, { persist = false })
  device:set_field("run_started_at", nil, { persist = false })
  device:set_field("last_stop_at", now_seconds(), { persist = false })
end

local function reset_cycle_tracking(device)
  device:set_field("run_accumulated_s", 0, { persist = false })
  device:set_field("last_stop_at", nil, { persist = false })
  device:set_field("run_started_at", nil, { persist = false })
end

-- =========================
-- started -> running (após X)
-- =========================
local function schedule_started_to_running(device)
  set_timer(device, "started_timer", STARTED_GRACE_SECONDS, function()
    local in_use = device:get_field("in_use") == true
    if in_use and get_cycle_state(device) == "started" then
      set_cycle_state(device, "running")
    end
  end)
end

-- =========================
-- completed hold (5 min) -> idle
-- =========================
local function schedule_completed_hold_to_idle(device)
  set_timer(device, "completed_hold_timer", COMPLETED_HOLD_SECONDS, function()
    if device:get_field("in_use") ~= true and get_cycle_state(device) == "completed" then
      set_cycle_state(device, "idle")
    end
  end)
end

-- =========================
-- Finaliza ciclo se parar estável por END_GAP
-- =========================
local function finalize_cycle_if_due(device)
  local acc = device:get_field("run_accumulated_s") or 0
  local last_stop = device:get_field("last_stop_at")

  if not last_stop then return end
  local gap = now_seconds() - last_stop
  if gap < END_GAP_SECONDS then return end

  if acc >= MIN_RUNTIME_SECONDS then
    device.log.info(string.format("Cycle finished. duration=%ds (~%.1f min)", acc, acc / 60))
    set_cycle_state(device, "completed")
    schedule_completed_hold_to_idle(device)
  else
    device.log.info(string.format("Ignored short run (noise). duration=%ds", acc))
    set_cycle_state(device, "idle")
  end

  reset_cycle_tracking(device)
end

-- =========================
-- Matter readiness guard (evita matter_channel nil)
-- =========================
local function matter_ready(device)
  return device ~= nil and device.matter_channel ~= nil
end

local function subscribe_and_refresh_if_ready(device)
  if not matter_ready(device) then
    return false
  end
  device:subscribe()
  device:send(BooleanState.attributes.StateValue:read(device))
  device:send(PowerSource.attributes.BatPercentRemaining:read(device))
  return true
end

local function retry_subscribe_and_refresh(device, attempts_left)
  attempts_left = attempts_left or 8
  if subscribe_and_refresh_if_ready(device) then return end
  if attempts_left <= 0 then
    device.log.warn(string.format("[%s] Matter channel not ready; giving up subscribe/refresh", device.label))
    return
  end
  device.thread:call_with_delay(1, function()
    retry_subscribe_and_refresh(device, attempts_left - 1)
  end)
end

-- =========================
-- Handlers
-- =========================
local function boolean_state_handler(driver, device, ib, response)
  local value = ib.data.value
  if value == nil then return end

  -- Seu mapeamento: false=rodando (em uso), true=parado
  local in_use = (value == false)
  device:set_field("in_use", in_use, { persist = false })

  if in_use then
    -- voltou a usar: cancela timers de parada e do hold de completed
    clear_timer(device, "debounce_timer")
    clear_timer(device, "completed_hold_timer")

    local current = get_cycle_state(device)

    -- Se estava idle ou completed, entra em started e agenda promoção
    if current == "idle" or current == "completed" then
      set_cycle_state(device, "started")
      schedule_started_to_running(device)
    end
    -- Se já estava started/running, mantém

    start_running(device)
    emit_utilization(device, true)
    return
  end

  -- possível parada: confirma após debounce
  set_timer(device, "debounce_timer", DEBOUNCE_SECONDS, function()
    emit_utilization(device, false)

    -- NÃO seta idle aqui imediatamente:
    -- deixa o estado "started/running" enquanto avaliamos gap e duração.
    stop_running_and_accumulate(device)
    finalize_cycle_if_due(device)

    -- Se não completou (ainda), e não está em uso, pode voltar para idle
    -- (Isso mantém a semântica: só fica "completed" quando realmente terminou)
    if device:get_field("in_use") ~= true and get_cycle_state(device) ~= "completed" then
      set_cycle_state(device, "idle")
    end
  end)
end

local function battery_handler(driver, device, ib, response)
  local raw = ib.data.value
  if raw == nil then return end

  local pct = math.floor(raw / 2)
  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end
  device:emit_event(capabilities.battery.battery(pct, { state_change = true }))
end

local function do_refresh(driver, device, command)
  -- refresh manual: só envia se Matter estiver pronto
  if not subscribe_and_refresh_if_ready(device) then
    retry_subscribe_and_refresh(device, 8)
  end
end

-- =========================
-- Lifecycle
-- =========================
local function device_init(driver, device)
  clear_timer(device, "debounce_timer")
  clear_timer(device, "started_timer")
  clear_timer(device, "completed_hold_timer")

  device:set_field("in_use", false, { persist = false })

  emit_utilization(device, false)
  set_cycle_state(device, "idle")

  -- Em Matter, init pode chegar antes do channel; usa retry seguro
  retry_subscribe_and_refresh(device, 8)
end

local function device_added(driver, device)
  emit_utilization(device, false)
  set_cycle_state(device, "idle")
end

local function device_driver_switched(driver, device, event, args)
  -- NÃO chame subscribe/send direto aqui (pode estar sem matter_channel)
  clear_timer(device, "debounce_timer")
  clear_timer(device, "started_timer")
  clear_timer(device, "completed_hold_timer")

  device:set_field("in_use", false, { persist = false })
  emit_utilization(device, false)
  set_cycle_state(device, "idle")

  -- agenda retry; dá tempo do runtime "reatar" o canal Matter
  device.thread:call_with_delay(1, function()
    retry_subscribe_and_refresh(device, 8)
  end)
end

-- =========================
-- Driver template
-- =========================
local driver_template = {
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = device_driver_switched
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh
    }
  },
  matter_handlers = {
    attr = {
      [BooleanState.ID] = {
        [BooleanState.attributes.StateValue.ID] = boolean_state_handler
      },
      [PowerSource.ID] = {
        [PowerSource.attributes.BatPercentRemaining.ID] = battery_handler
      }
    }
  }
}

local driver = MatterDriver("weber-mb-utilization", driver_template)
driver:run()
