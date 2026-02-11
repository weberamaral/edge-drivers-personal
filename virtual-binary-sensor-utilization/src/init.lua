local MatterDriver = require "st.matter.driver"
local capabilities = require "st.capabilities"

local clusters = require "st.matter.clusters" -- conforme doc oficial
local BooleanState = clusters.BooleanState
local PowerSource = clusters.PowerSource

local DEBOUNCE_SECONDS = 20 -- ajuste aqui (ex.: 10, 20, 30)

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

  local in_use = (value == false)

  if in_use then
    -- Publica rodando imediatamente e cancela qualquer timer de "parou"
    clear_timer(device, "debounce_timer")
    emit_utilization(device, true)
  else
    -- Só publica parado depois de estabilizar
    set_timer(device, "debounce_timer", DEBOUNCE_SECONDS, function()
      emit_utilization(device, false)
    end)
  end
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
