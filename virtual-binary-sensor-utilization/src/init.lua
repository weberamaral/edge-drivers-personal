local MatterDriver        = require "st.matter.driver"
local capabilities        = require "st.capabilities"

local clusters            = require "st.matter.clusters" -- conforme doc oficial
local BooleanState        = clusters.BooleanState
local PowerSource         = clusters.PowerSource

local DEBOUNCE_SECONDS    = 20  -- ajuste aqui (ex.: 10, 20, 30)

local MIN_RUNTIME_SECONDS = 300 -- ex.: 2 min. Ajuste conforme sua realidade
local END_GAP_SECONDS     = 480 -- 8 min (parado estável = fim de ciclo)

local function now_seconds()
  -- Edge Lua tem os.time() (segundos). Suficiente pra duração.
  return os.time()
end

-- helpers
local function start_running(device)
  if not device:get_field("run_started_at") then
    device:set_field("run_started_at", now_seconds(), { persist = false })
  end
end

local function stop_running_and_accumulate(device)
  local started = device:get_field("run_started_at")
  if not started then return end

  local acc = device:get_field("run_accumulated_s") or 0
  local dur = now_seconds() - started
  if dur < 0 then dur = 0 end

  device:set_field("run_accumulated_s", acc + dur, { persist = false })
  device:set_field("run_started_at", nil, { persist = false })
  device:set_field("last_stop_at", now_seconds(), { persist = false })
end

local function finalize_cycle_if_due(device)
  local acc = device:get_field("run_accumulated_s") or 0
  local last_stop = device:get_field("last_stop_at")

  if not last_stop then return end
  local gap = now_seconds() - last_stop
  if gap < END_GAP_SECONDS then return end

  -- Aqui consideramos que o ciclo terminou
  if acc >= MIN_RUNTIME_SECONDS then
    device.log.info(string.format("Cycle finished. duration=%ds (~%.1f min)", acc, acc / 60))
    -- Se quiser, aqui no futuro você emite custom capability com duração/timestamp.
  else
    device.log.info(string.format("Ignored short run (noise). duration=%ds", acc))
  end

  -- Reset para o próximo ciclo
  device:set_field("run_accumulated_s", 0, { persist = false })
  device:set_field("last_stop_at", nil, { persist = false })
end

local function set_timer(device, field_name, seconds, fn)
  -- Cancela timer anterior, se existir
  local old = device:get_field(field_name)
  if old then
    device.thread:cancel_timer(old)
  end
  -- Cria novo timer
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

local function emit_utilization(device, in_use)
  local status = in_use and "inUse" or "notInUse"
  device:emit_event(capabilities.applianceUtilization.status(status))
end

local function boolean_state_handler(driver, device, ib, response)
  local value = ib.data.value
  if value == nil then return end

  local in_use = (value == false) -- false=rodando, true=parado

  if in_use then
    -- Rodando: cancela timer de "parou", inicia/retoma contagem
    clear_timer(device, "debounce_timer")
    start_running(device)
    emit_utilization(device, true)
    return
  end

  -- Possível parada: confirma só após debounce
  set_timer(device, "debounce_timer", DEBOUNCE_SECONDS, function()
    emit_utilization(device, false)

    -- Fecha o "trecho" rodando e acumula
    stop_running_and_accumulate(device)

    -- Se ficar parado tempo suficiente, considera fim de ciclo
    finalize_cycle_if_due(device)
  end)
end

local function battery_handler(driver, device, ib, response)
  local raw = ib.data.value -- ex.: 200
  if raw == nil then return end

  -- Matter costuma usar 0..200 (meio por cento)
  local pct = math.floor(raw / 2)
  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end

  device:emit_event(capabilities.battery.battery(pct))
end

local function do_refresh(driver, device, command)
  device:send(BooleanState.attributes.StateValue:read(device))
  device:send(PowerSource.attributes.BatPercentRemaining:read(device))
end

local function device_init(driver, device)
  clear_timer(device, "debounce_timer")
  device:subscribe()
  emit_utilization(device, false) -- assume parado
end

local function device_added(driver, device)
  -- opcional: estado inicial
  emit_utilization(device, false)
end

local function device_driver_switched(driver, device, event, args)
  clear_timer(device, "debounce_timer")
  device:subscribe()
  emit_utilization(device, false)

  device:send(BooleanState.attributes.StateValue:read(device))
  device:send(PowerSource.attributes.BatPercentRemaining:read(device))
end

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
