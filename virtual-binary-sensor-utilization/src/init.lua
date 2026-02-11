local MatterDriver = require "st.matter.driver"
local capabilities = require "st.capabilities"

local clusters = require "st.matter.clusters" -- conforme doc oficial
local BooleanState = clusters.BooleanState
local PowerSource = clusters.PowerSource

local function emit_utilization(device, in_use)
  local status = in_use and "inUse" or "notInUse"
  device:emit_event(capabilities.applianceUtilization.status(status))
end

local function boolean_state_handler(driver, device, ib, response)
  local value = ib.data.value -- true/false
  if value == nil then return end

  -- seu caso: true = parado, false = rodando
  local in_use = (value == false)
  emit_utilization(device, in_use)
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
  device:subscribe()
  emit_utilization(device, false) -- assume parado no boot
end

local function device_added(driver, device)
  -- opcional: estado inicial
  emit_utilization(device, false)
end

local function device_driver_switched(driver, device, event, args)
  -- quando troca driver em device já existente, vale re-subscrever e atualizar estado
  device:subscribe()
  emit_utilization(device, false)

  -- opcional: ler imediatamente do device
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
