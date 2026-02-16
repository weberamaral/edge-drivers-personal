local MatterDriver      = require "st.matter.driver"
local capabilities      = require "st.capabilities"

local cycleCap          = capabilities["signalprogram56169.cycleState"]
local cycleCountCap     = capabilities["signalprogram56169.cycleCount"]

local clusters          = require "st.matter.clusters"
local BooleanState      = clusters.BooleanState
local PowerSource       = clusters.PowerSource

-- Ajustes
local RUNNING_AFTER_SEC = 120 -- 2 min: Ciclo "Em execução"
local IDLE_AFTER_SEC    = 300 -- 5 min parado: Ciclo "Parado"
local POLL_INTERVAL     = 30  -- segundos (30 ou 60 é ideal)

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

local function start_polling(device)
  -- evita duplicar polling
  if device:get_field("polling_started") then return end
  device:set_field("polling_started", true, { persist = false })

  local function poll_tick()
    device:send(BooleanState.attributes.StateValue:read(device))
    device:send(PowerSource.attributes.BatPercentRemaining:read(device))

    -- loop: reagenda o próximo tick
    set_timer(device, "poll_timer", POLL_INTERVAL, poll_tick)
  end

  -- começa rápido após init/switch (pra atualizar UI logo)
  set_timer(device, "poll_timer", 1, poll_tick)
end

local function stop_polling(device)
  clear_timer(device, "poll_timer")
  device:set_field("polling_started", false, { persist = false })
end

local function emit_utilization(device, in_use)
  local status = in_use and "inUse" or "notInUse"
  device:emit_event(capabilities.applianceUtilization.status(status))
end

local function set_cycle_state(device, new_state)
  local current = device:get_field("cycle_state") or "idle"
  if current == new_state then return end
  device:set_field("cycle_state", new_state, { persist = false })
  device:emit_event(cycleCap.cycleState(new_state, { state_change = true }))
end

local function clear_all_timers(device)
  clear_timer(device, "running_timer")
  clear_timer(device, "idle_timer")
  stop_polling(device)
end

-- ===== Cycle Count helpers =====

local function get_cycle_count(device)
  local n = device:get_field("cycle_count")
  if n == nil then n = 0 end
  return n
end

local function emit_cycle_count(device, n)
  device:emit_event(cycleCountCap.count(n, { state_change = true }))
end

local function increment_cycle_count(device)
  local n = get_cycle_count(device) + 1
  device:set_field("cycle_count", n, { persist = true })
  emit_cycle_count(device, n)
end

local function reset_cycle_count(device)
  device:set_field("cycle_count", 0, { persist = true })
  emit_cycle_count(device, 0)
end

-- ===== State machine =====

-- Em uso:
-- 1) ciclo = started imediato
-- 2) após 2 min (se ainda em uso) -> running
local function on_in_use(device)
  clear_timer(device, "idle_timer") -- se estava parado, cancela retorno ao idle

  device:set_field("in_use", true, { persist = false })
  emit_utilization(device, true)
  set_cycle_state(device, "started")

  set_timer(device, "running_timer", RUNNING_AFTER_SEC, function()
    local still_in_use = device:get_field("in_use") == true
    if still_in_use then
      set_cycle_state(device, "running")
    end
  end)
end

-- Não está em uso:
-- 1) ciclo = completed imediato + incrementa contador
-- 2) após 5 min (se ainda não em uso) -> idle
local function on_not_in_use(device)
  clear_timer(device, "running_timer") -- não faz sentido virar running se parou

  device:set_field("in_use", false, { persist = false })
  emit_utilization(device, false)

  -- marca completed imediatamente
  set_cycle_state(device, "completed")

  -- conta 1 ciclo completo
  increment_cycle_count(device)

  set_timer(device, "idle_timer", IDLE_AFTER_SEC, function()
    local still_not_in_use = device:get_field("in_use") == false
    if still_not_in_use then
      set_cycle_state(device, "idle")
    end
  end)
end

local function boolean_state_handler(driver, device, ib, response)
  local value = ib.data.value
  if value == nil then return end

  -- Pelo seu padrão: false = rodando, true = parado
  local in_use = (value == false)

  local prev = device:get_field("in_use")
  if prev == nil then prev = false end

  -- Se não mudou, não faz nada
  if in_use == prev then return end

  if in_use then
    on_in_use(device)
  else
    on_not_in_use(device)
  end
end

local function battery_handler(driver, device, ib, response)
  local raw = ib.data.value
  if raw == nil then return end

  local pct = math.floor(raw / 2)
  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end

  device:emit_event(capabilities.battery.battery(pct))
end

local function do_refresh(driver, device, command)
  device:send(BooleanState.attributes.StateValue:read(device))
  device:send(PowerSource.attributes.BatPercentRemaining:read(device))
end

-- Command handler: reset contador
local function reset_count_command(driver, device, command)
  reset_cycle_count(device)
end

local function device_init(driver, device)
  clear_all_timers(device)
  device:subscribe()

  device:set_field("in_use", false, { persist = false })
  emit_utilization(device, false)
  set_cycle_state(device, "idle")

  start_polling(device)
end

local function device_added(driver, device)
  device:set_field("in_use", false, { persist = false })
  emit_utilization(device, false)
  set_cycle_state(device, "idle")

  emit_cycle_count(device, get_cycle_count(device))

  start_polling(device)
end

local function device_driver_switched(driver, device, event, args)
  clear_all_timers(device)
  device:subscribe()

  device:set_field("in_use", false, { persist = false })
  emit_utilization(device, false)
  set_cycle_state(device, "idle")

  emit_cycle_count(device, get_cycle_count(device))

  -- leitura imediata
  device:send(BooleanState.attributes.StateValue:read(device))
  device:send(PowerSource.attributes.BatPercentRemaining:read(device))

  start_polling(device)
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
    },
    [cycleCountCap.ID] = {
      ["reset"] = reset_count_command
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
