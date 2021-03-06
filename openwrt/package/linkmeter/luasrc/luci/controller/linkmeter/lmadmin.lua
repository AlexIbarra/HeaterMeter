module("luci.controller.linkmeter.lmadmin", package.seeall)

function index()
  local node = entry({"admin", "lm"}, alias("admin", "lm", "conf"), "LinkMeter",60)
  node.index = true
  entry({"admin", "lm", "home"}, template("linkmeter/index"), "Home", 10)
  entry({"admin", "lm", "archive"}, template("linkmeter/archive"), "Archive", 30)
  entry({"admin", "lm", "fw"}, call("action_fw"), "AVR Firmware", 40)
  entry({"admin", "lm", "conf"}, template("linkmeter/conf"), "Configuration", 50)
  entry({"admin", "lm", "wifi"}, post_on({join = true}, "action_wifi"), "Wifi", 60)
  entry({"admin", "lm", "credits"}, template("linkmeter/credits"), "Credits", 70)

  entry({"admin", "lm", "usercss"}, cbi("linkmeter/usercss"))
  entry({"admin", "lm", "apikey"}, template("linkmeter/qr-apikey"))

  entry({"admin", "lm", "stashdb"}, call("action_stashdb"))
  entry({"admin", "lm", "reboot"}, call("action_reboot"))
  entry({"admin", "lm", "set"}, call("action_set"))
  entry({"admin", "lm", "altest"}, call("action_alarm_test"))
  entry({"admin", "lm", "wifi_scan"}, call("action_wifi_scan"))

  if node.inreq and nixio.fs.access("/usr/share/linkmeter/alarm") then
    entry({"admin", "lm", "alarm"}, cbi("linkmeter/alarm", {hidesavebtn=true}),
      "Alarms", 20)
    entry({"admin", "lm", "alarm-scripts"}, form("linkmeter/alarm-scripts"),
      "Alarm Scripts", 25)
  end

  -- home and lighthome displays have both auth (under admin) and guest pages
  entry({"lm", "light"}, call("action_light_index"))
  entry({"admin", "lm", "light"}, call("action_light_index"))
end

function api_file_handler(fname)
  local file
  luci.http.setfilehandler(
    function(meta, chunk, eof)
      if not file and chunk and #chunk > 0 then
        file = io.open(fname, "w")
      end
      if file and chunk then
        file:write(chunk)
      end
      if file and eof then
        file:close()
      end
    end
  )
end

function api_post_fw(fname)
  luci.http.prepare_content("text/plain")
  local pipe = require "luci.controller.admin.system".ltn12_popen(
    "/usr/bin/avrupdate %q" % fname)
  return luci.ltn12.pump.all(pipe, luci.http.write)
end

function action_fw()
  local hex = "/tmp/hm.hex"

  local step = tonumber(luci.http.formvalue("step") or 1)
  local has_upload = luci.http.formvalue("hexfile")
  local hexpath = luci.http.formvalue("hexpath")
  local web_update = hexpath and hexpath:find("^http[s]?://")

  if step == 1 then
    api_file_handler(hex)

    if has_upload and nixio.fs.access(hex) then
      step = 2
    elseif hexpath and (web_update or nixio.fs.access(hexpath)) then
      step = 2
      hex = hexpath
    else
      nixio.fs.unlink(hex)
    end
    return luci.template.render("linkmeter/fw", {step=step, hex=hex})
  end
  if step == 3 then
    return api_post_fw(luci.http.formvalue("hex"))
  end
end

function action_stashdb()
  local http = require "luci.http"
  local uci = luci.model.uci.cursor()

  local RRD_FILE = uci:get("linkmeter", "daemon", "rrd_file")
  local STASH_PATH = uci:get("linkmeter", "daemon", "stashpath") or "/root"
  local restoring = http.formvalue("restore")
  local backup = http.formvalue("backup")
  local resetting = http.formvalue("reset")
  local deleting = http.formvalue("delete")
  local renaming = http.formvalue("rename")
  local stashfile = http.formvalue("rrd") or "hm.rrd"

  -- directory traversal
  if stashfile:find("[/\\]+") then
    http.status(400, "Bad Request")
    http.prepare_content("text/plain")
    return http.write("Invalid stashfile specified: "..stashfile)
  end
  if renaming and renaming:find("[/\\]+") then
    http.status(400, "Bad Request")
    http.prepare_content("text/plain")
    return http.write("Invalid rename specified: "..renaming)
  end
  -- POST-only for these operations
  if http.getenv("REQUEST_METHOD") ~= "POST" then
    http.status(405, "Not Allowed")
    http.prepare_content("text/plain")
    return http.write("POST only")
  end

  -- Backup all
  if backup == "1" then
    local backup_cmd = "cd %q && tar cz *.rrd *.json" % STASH_PATH
    local reader = require "luci.controller.admin.system".ltn12_popen(backup_cmd)
    http.header("Content-Disposition",
      'attachment; filename="lmstash-%s-%s.tar.gz"' % {
      luci.sys.hostname(), os.date("%Y-%m-%d")})
    http.prepare_content("application/x-targz")
    return luci.ltn12.pump.all(reader, luci.http.write)
  end

  local result
  http.prepare_content("text/plain")

  -- the stashfile should start with a slash
  if stashfile:sub(1,1) ~= "/" then stashfile = "/"..stashfile end
  -- and end with .rrd
  if stashfile:sub(-4) ~= ".rrd" then stashfile = stashfile..".rrd" end

  stashfile = STASH_PATH..stashfile

  -- Delete
  if deleting == "1" then
    result = nixio.fs.unlink(stashfile)
    http.write("Deleting "..stashfile)
    stashfile = stashfile:gsub("\.rrd$", ".json")
    if nixio.fs.access(stashfile) then
      nixio.fs.unlink(stashfile)
      http.write("\nDeleting "..stashfile)
    end

  -- Activate stash to current -OR- reset database
  elseif restoring == "1" or resetting == "1" then
    require "lmclient"
    local lm = LmClient()
    lm:query("$LMDC,0", true) -- stop serial process
    if resetting == "1" then
      nixio.fs.unlink("/root/autobackup.rrd")
      result = nixio.fs.unlink(RRD_FILE)
      http.write("Removing autobackup\nResetting "..RRD_FILE)
    else
      result = nixio.fs.copy(stashfile, RRD_FILE)
      http.write("Restoring "..stashfile.." to "..RRD_FILE)
    end
    lm:query("$LMDC,1") -- start serial process and close connection

  -- Rename
  elseif renaming then
    -- Must end with .rrd, will *NOT* start with /
    if renaming:sub(-4) ~= ".rrd" then renaming = renaming..".rrd" end
    if nixio.fs.access(STASH_PATH .. '/' .. renaming) then
      http.write("Can not rename, target file [" .. renaming .. "] exists")
      result = false
    else
      result = nixio.fs.rename(stashfile, STASH_PATH .. '/' .. renaming)
      http.write("Renaming " .. stashfile .. " to " .. renaming)
      if result then
        stashfile = stashfile:gsub("\.rrd$", ".json")
        renaming = renaming:gsub("\.rrd$", ".json")
        result = nixio.fs.rename(stashfile, STASH_PATH .. '/' .. renaming)
        http.write("\nRenaming " .. stashfile .. " to " .. renaming)
      end
    end

  -- Actual Stash
  else
    if not nixio.fs.stat(STASH_PATH) then
      nixio.fs.mkdir(STASH_PATH)
    end
    result = nixio.fs.copy(RRD_FILE, stashfile)
    http.write("Stashing "..RRD_FILE.." to "..stashfile)
    -- Also snapshot the HeaterMeter configuration for probe names, etc
    require "lmclient"
    local conf = LmClient():query("$LMCF")
    if conf ~= "{}" then
      stashfile = stashfile:gsub("\.rrd$", ".json")
      nixio.fs.writefile(stashfile, conf)
      http.write("\nStashing current config to "..stashfile)
    end
  end

  if result then
    http.write("\nOK")
  else
    http.write("\nERR")
  end
end

function action_reboot()
  local http = require "luci.http"
  http.prepare_content("text/plain")

  http.write("Rebooting AVR... ")
  require "lmclient"
  http.write(LmClient():query("$LMRB") or "FAILED")
end

function api_set(vals)
  local dsp = require "luci.dispatcher"
  local http = require "luci.http"

  -- If there's a rawset, explode the rawset into individual items
  local rawset = vals.rawset
  if rawset then
    -- remove /set? or set? if supplied
    rawset = rawset:gsub("^/?set%?","")
    vals = {}
    for pair in rawset:gmatch( "[^&;]+" ) do
      local key = pair:match("^([^=]+)")
      local val = pair:match("^[^=]+=(.+)$")
      if key and val then
        vals[key] = val
      end
    end
  end

  http.prepare_content("text/plain")

  -- The apikey and lidtrack_enabled is also set this way, but remove them from the table
  local uci
  local set_apikey = vals["lm_apikey"]
  if set_apikey ~= nil and set_apikey ~= "" then
    uci = uci or require("uci"):cursor()
    uci:set("linkmeter", "api", "key", set_apikey)
    http.write("API key updated\n")
    vals["lm_apikey"] = nil
  end
  local set_lidtrack = vals["lm_lidtrack_enabled"]
  if set_lidtrack ~= nil and set_lidtrack ~= "" then
    uci = uci or require("uci"):cursor()
    uci:set("linkmeter", "daemon", "lidtrack_enabled", set_lidtrack)
    http.write("LidTrack " .. (set_lidtrack == "1" and "enabled" or "disabled") .. "\n")
    vals["lm_lidtrack_enabled"] = nil
  end
  if uci then
    uci:commit("linkmeter")
  end

  -- Make sure the user passed some values to set
  local cnt = 0
  -- Can't use #vals because table actually could be a metatable with an indexer
  for _ in pairs(vals) do cnt = cnt + 1 end
  if cnt == 0 then
    if uci == nil then
      http.status(400, "Bad Request")
      http.write("No values specified")
    end
    return
  end

  require("lmclient")
  local lm = LmClient()

  http.write("User %s setting %d values...\n" % {dsp.context.authuser, cnt})
  local firstTime = true
  for k,v in pairs(vals) do
    -- Pause 100ms between commands to allow HeaterMeter to work
    if firstTime then
      firstTime = nil
    else
      nixio.nanosleep(0, 100000000)
    end

    -- Convert XX% setpoint to -XX, OFF -> O
    if (k == "sp") then
      v = v:upper() -- HM expects units to be uppercase
      local dig, units = v:match("^(%d*).-([ACFRO%%]*)$")
      if units == "%" then v = "-" .. dig end
      if units == "OFF" then v = "O" end
    end

    local result, err = lm:query("$LMST,%s,%s" % {k,v}, true)
    http.write("%s to %s = %s\n" % {k,v, result or err})
    if err then break end
  end
  lm:close()
  http.write("Done!")
end

function action_set()
  api_set(luci.http.formvalue())
end

function action_light_index()
  require "lmclient"
  local json = require("luci.jsonc")
  local result, err = LmClient():query("$LMSU")
  if result then
      local lm = json.parse(result)
      luci.template.render("linkmeter/light", {
        lm = lm,
        lmraw = result,
        build_url = luci.dispatcher.build_url,
        authuser = luci.dispatcher.context.authuser
      })
  else
    luci.dispatcher.error500("Status read failed: " .. err or "Unknown")
  end
end

function action_alarm_test()
  local http = require "luci.http"
  local pnum = http.formvalue("pnum")
  local al_type = http.formvalue("type")
  if pnum and al_type then
    require "lmclient"
    local lmc = LmClient()

    -- trigger alarm
    local result, err = lmc:query("$LMAT,"..pnum..","..al_type, true)
    http.write(("Testing alarm %s%s... %s"):format(pnum, al_type,
      result or "ERR"))

    -- disable alarms
    lmc:query("$LMAT,"..pnum)
  else
    luci.dispatcher.error500("Missing pnum or type parameter")
  end
end

function action_wifi_scan()
  local device = "wlan0"
  local sys = require "luci.sys"
  --local http = require "luci.http"
  local json = require "luci.jsonc"

  luci.http.prepare_content("application/json")

  local iw = sys.wifi.getiwinfo(device)
  local retVal
  if iw then
    retVal = iw.scanlist or {}
  else
    retVal = {error="NODEV", message="No info for device " .. device}
  end

  return luci.http.write(json.stringify(retVal))
end

function action_wifi()
  local ssid = luci.http.formvalue("join")
  local encrypt = luci.http.formvalue("encryption")
  local key = luci.http.formvalue("key")
  local mode = luci.http.formvalue("mode") or "sta"
  local band = luci.http.formvalue("band")
  if ssid and encrypt and
    (encrypt == "none" or key ~= "") then
    local cmd = '/usr/bin/wifi-client -s %q -e %q -m %q' % { ssid, encrypt, mode}
    if key then cmd = cmd .. (' -p %q' % { key }) end
    if band then cmd = cmd .. ' -b ' .. band end
    -- Only supply a channel if AP mode and the user set a channel
    -- otherwise let the script default it
    local channel = luci.http.formvalue("channel")
    if mode == "ap" and channel then
      cmd = cmd .. ' -c ' .. channel
    end

    luci.http.prepare_content("text/plain")
    luci.http.write((mode == "sta" and "Joining" or "Creating") .. " network '" .. ssid .. "'\r\n")
    luci.http.close()

    luci.sys.call(cmd)
    luci.util.ubus("network", "reload", {})
  end
  return luci.template.render("linkmeter/wifi", {})
end
