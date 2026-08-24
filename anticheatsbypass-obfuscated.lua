local task = task or {
    spawn  = function(f) coroutine.wrap(f)() end,
    wait   = function(t) local s=os.clock() while os.clock()-s<(t or 0) do end end,
    cancel = function() end,
}

local realDump = string.dump

local EXEC = {
    getupvalues       = type(getupvalues)       == "function" and getupvalues       or nil,
    getconstants      = type(getconstants)      == "function" and getconstants      or nil,
    getprotos         = type(getprotos)         == "function" and getprotos         or nil,
    islclosure        = type(islclosure)        == "function" and islclosure        or nil,
    iscclosure        = type(iscclosure)        == "function" and iscclosure        or nil,
    hookfunction      = type(hookfunction)      == "function" and hookfunction      or nil,
    newcclosure       = type(newcclosure)       == "function" and newcclosure       or nil,
    checkcaller       = type(checkcaller)       == "function" and checkcaller       or nil,
    decompile         = type(decompile)         == "function" and decompile         or nil,
    getrawmetatable   = type(getrawmetatable)   == "function" and getrawmetatable   or nil,
    setrawmetatable   = type(setrawmetatable)   == "function" and setrawmetatable   or nil,
    setreadonly       = type(setreadonly)       == "function" and setreadonly       or nil,
    isreadonly        = type(isreadonly)        == "function" and isreadonly        or nil,
    clonefunction     = type(clonefunction)     == "function" and clonefunction     or nil,
    getscriptbytecode = type(getscriptbytecode) == "function" and getscriptbytecode or nil,
    filtergc          = type(filtergc)          == "function" and filtergc          or nil,
}

local LEVEL     = {INFO=1, WARN=2, CRIT=3}
local LEVEL_TAG = {[1]="INFO", [2]="WARN", [3]="CRIT"}

local AlertLog   = {}
local AlertCBs   = {}
local Protected  = {}
local NativeSnap = {}
local RateTrk    = {}
local ScanThr    = nil
local Active     = false

local RATE_WIN = 2.0
local RATE_MAX = 8

local function rateOk(src)
    local now = os.clock()
    RateTrk[src] = RateTrk[src] or {n=0, t=now}
    local r = RateTrk[src]
    if now - r.t > RATE_WIN then r.n=0; r.t=now end
    r.n = r.n + 1
    return r.n <= RATE_MAX
end

local function fireAlert(lvl, src, detail)
    if not rateOk(src) then return end
    local e = {
        level  = lvl,
        tag    = LEVEL_TAG[lvl] or "?",
        src    = src,
        detail = tostring(detail or ""),
        t      = os.clock(),
    }
    AlertLog[#AlertLog+1] = e
    print(("[ANTISPY][%s] %s | %s"):format(e.tag, e.src, e.detail))
    for _, cb in ipairs(AlertCBs) do pcall(cb, e) end
end

local function fnv32(s)
    local h = 2166136261
    for i = 1, math.min(#s, 512) do
        h = bit32.bxor(h, s:byte(i))
        h = (h * 16777619) % 4294967296
    end
    return h
end

local function fingerprint(fn)
    if type(fn) ~= "function" then return nil end
    local isLua = not EXEC.islclosure or EXEC.islclosure(fn)
    local fp = {
        addr       = tostring(fn),
        isLua      = isLua,
        byteHash   = nil,
        byteLen    = nil,
        upCount    = nil,
        constCount = nil,
        protoCount = nil,
    }
    if isLua then
        local ok, dump = pcall(realDump, fn, true)
        if ok and type(dump) == "string" then
            fp.byteHash = fnv32(dump)
            fp.byteLen  = #dump
        end
        if EXEC.getupvalues then
            local ok2, ups = pcall(EXEC.getupvalues, fn)
            if ok2 then fp.upCount = #ups end
        else
            local i = 1
            while debug.getupvalue(fn, i) do i = i+1 end
            fp.upCount = i - 1
        end
        if EXEC.getconstants then
            local ok3, cc = pcall(EXEC.getconstants, fn)
            if ok3 then fp.constCount = #cc end
        end
        if EXEC.getprotos then
            local ok4, pp = pcall(EXEC.getprotos, fn)
            if ok4 then fp.protoCount = #pp end
        end
    end
    return fp
end

local function fpDiff(s, c)
    if s.addr ~= c.addr then
        return true, ("addr %s->%s"):format(s.addr:sub(-10), c.addr:sub(-10))
    end
    if s.byteHash and c.byteHash and s.byteHash ~= c.byteHash then
        return true, ("bytehash %u->%u"):format(s.byteHash, c.byteHash)
    end
    if s.byteLen and c.byteLen and s.byteLen ~= c.byteLen then
        return true, ("bytelen %d->%d"):format(s.byteLen, c.byteLen)
    end
    if s.upCount ~= nil and c.upCount ~= nil and s.upCount ~= c.upCount then
        return true, ("upcount %d->%d"):format(s.upCount, c.upCount)
    end
    return false, "clean"
end

local function isProtected(fn)
    for _, e in ipairs(Protected) do
        if e.original == fn or e.wrapped == fn then return true, e end
    end
    return false, nil
end

local function callerOk()
    if EXEC.checkcaller then return EXEC.checkcaller() end
    return true
end

local function shieldDebug()
    local R = {
        getupvalue = debug.getupvalue,
        getlocal   = type(debug.getlocal)  == "function" and debug.getlocal  or nil,
        sethook    = debug.sethook,
        gethook    = type(debug.gethook)   == "function" and debug.gethook   or nil,
        getinfo    = debug.getinfo,
        getfenv    = type(debug.getfenv)   == "function" and debug.getfenv   or nil,
        traceback  = debug.traceback,
    }

    debug.getupvalue = function(fn, idx)
        local hit, entry = isProtected(fn)
        if hit then
            fireAlert(LEVEL.CRIT, "debug.getupvalue",
                ("blocked [%s] idx=%d"):format(entry.name, idx))
            return "__ANTISPY__", nil
        end
        return R.getupvalue(fn, idx)
    end

    debug.sethook = function(fn, mask, count)
        fireAlert(LEVEL.CRIT, "debug.sethook",
            ("hook plant — mask=%s fn=%s"):format(tostring(mask), tostring(fn)))
        if not callerOk() then
            fireAlert(LEVEL.CRIT, "debug.sethook", "foreign caller blocked")
            return
        end
        return R.sethook(fn, mask, count)
    end

    if R.gethook then
        debug.gethook = function(thread)
            fireAlert(LEVEL.WARN, "debug.gethook",
                ("hook probe thread=%s"):format(tostring(thread)))
            return R.gethook(thread)
        end
    end

    debug.getinfo = function(target, flags)
        if type(target) == "function" then
            local hit, entry = isProtected(target)
            if hit then
                fireAlert(LEVEL.WARN, "debug.getinfo",
                    ("probe on protected [%s]"):format(entry.name))
            end
        end
        return R.getinfo(target, flags)
    end

    if R.getlocal then
        debug.getlocal = function(level, localIdx)
            if not callerOk() then
                fireAlert(LEVEL.WARN, "debug.getlocal",
                    ("local probe level=%s idx=%s"):format(tostring(level), tostring(localIdx)))
            end
            return R.getlocal(level, localIdx)
        end
    end

    if R.getfenv then
        debug.getfenv = function(fn)
            local hit, entry = isProtected(fn)
            if hit then
                fireAlert(LEVEL.CRIT, "debug.getfenv",
                    ("env extraction blocked [%s]"):format(entry and entry.name or "?"))
                return {}
            end
            return R.getfenv(fn)
        end
    end

    print("[ANTISPY] debug shield: getupvalue / sethook / gethook / getinfo / getlocal / getfenv")
end

local function shieldHookfunction()
    if not EXEC.hookfunction then
        print("[ANTISPY] hookfunction: unavailable")
        return
    end
    local realHook = EXEC.hookfunction
    pcall(function()
        EXEC.hookfunction(realHook, function(target, replacement)
            local hit, entry = isProtected(target)
            if hit then
                fireAlert(LEVEL.CRIT, "hookfunction",
                    ("hook blocked on [%s]"):format(entry.name))
                if entry.killOnHook then
                    error("[ANTISPY] hookfunction blocked — " .. entry.name)
                end
                return target
            end
            return realHook(target, replacement)
        end)
    end)
    print("[ANTISPY] hookfunction: interceptor active")
end

local function shieldStringDump()
    -- Check if string.dump is writable first
    local success, err = pcall(function()
        string.dump = string.dump
    end)
    
    if not success then
        print("[ANTISPY] string.dump is readonly, using alternative protection")
        -- Alternative: use hookfunction if available
        if EXEC.hookfunction and EXEC.getscriptbytecode then
            local realDumpFn = string.dump
            local hooked = false
            pcall(function()
                EXEC.hookfunction(realDumpFn, function(fn, strip)
                    local hit, entry = isProtected(fn)
                    if hit then
                        fireAlert(LEVEL.CRIT, "string.dump",
                            ("bytecode extraction blocked [%s]"):format(entry.name))
                        error("[ANTISPY] string.dump blocked on protected function")
                    end
                    return realDumpFn(fn, strip)
                end)
                hooked = true
            end)
            if hooked then
                print("[ANTISPY] string.dump: interceptor active (via hookfunction)")
                return
            end
        end
        print("[ANTISPY] string.dump: unable to protect (readonly + no hookfunction)")
        return
    end
    
    -- If writable, proceed with normal interception
    local realDumpFn = string.dump
    string.dump = function(fn, strip)
        local hit, entry = isProtected(fn)
        if hit then
            fireAlert(LEVEL.CRIT, "string.dump",
                ("bytecode extraction blocked [%s]"):format(entry.name))
            error("[ANTISPY] string.dump blocked on protected function")
        end
        return realDumpFn(fn, strip)
    end
    print("[ANTISPY] string.dump: shield active")
end

local function shieldExecAPIs()
    local function intercept(name, realFn, handler)
        if not realFn or not EXEC.hookfunction then return end
        pcall(function()
            EXEC.hookfunction(realFn, handler)
            print(("[ANTISPY] %s: interceptor active"):format(name))
        end)
    end

    if EXEC.getupvalues then
        local R = EXEC.getupvalues
        intercept("getupvalues", R, function(fn)
            local hit, entry = isProtected(fn)
            if hit then
                fireAlert(LEVEL.CRIT, "getupvalues",
                    ("upvalue table blocked [%s]"):format(entry.name))
                return {}
            end
            return R(fn)
        end)
    end

    if EXEC.getconstants then
        local R = EXEC.getconstants
        intercept("getconstants", R, function(fn)
            local hit, entry = isProtected(fn)
            if hit then
                fireAlert(LEVEL.CRIT, "getconstants",
                    ("constant table blocked [%s]"):format(entry.name))
                return {}
            end
            return R(fn)
        end)
    end

    if EXEC.getprotos then
        local R = EXEC.getprotos
        intercept("getprotos", R, function(fn)
            local hit, entry = isProtected(fn)
            if hit then
                fireAlert(LEVEL.CRIT, "getprotos",
                    ("proto table blocked [%s]"):format(entry.name))
                return {}
            end
            return R(fn)
        end)
    end

    if EXEC.decompile then
        local R = EXEC.decompile
        intercept("decompile", R, function(fn)
            local hit, entry = isProtected(fn)
            if hit then
                fireAlert(LEVEL.CRIT, "decompile",
                    ("source decompile blocked [%s]"):format(entry.name))
                return ""
            end
            return R(fn)
        end)
    end

    if EXEC.clonefunction then
        local R = EXEC.clonefunction
        intercept("clonefunction", R, function(fn)
            local hit, entry = isProtected(fn)
            if hit then
                fireAlert(LEVEL.CRIT, "clonefunction",
                    ("clone blocked [%s]"):format(entry.name))
                return fn
            end
            return R(fn)
        end)
    end

    if EXEC.getscriptbytecode then
        local R = EXEC.getscriptbytecode
        intercept("getscriptbytecode", R, function(script)
            fireAlert(LEVEL.WARN, "getscriptbytecode",
                ("bytecode read on %s"):format(tostring(script)))
            return R(script)
        end)
    end
end

local function shieldCoroutines()
    local realCreate = coroutine.create
    local realResume = coroutine.resume
    local realWrap   = coroutine.wrap
    local ownership  = setmetatable({}, {__mode="k"})

    coroutine.create = function(fn)
        local co = realCreate(fn)
        ownership[co] = {creator=coroutine.running(), fn=fn, at=os.clock()}
        return co
    end

    coroutine.resume = function(co, ...)
        local info = ownership[co]
        if info then
            local caller = coroutine.running()
            if caller ~= info.creator and not callerOk() then
                fireAlert(LEVEL.WARN, "coroutine.resume",
                    ("foreign thread — coroutine age=%.4fs"):format(os.clock()-info.at))
            end
        end
        return realResume(co, ...)
    end

    coroutine.wrap = function(fn)
        local hit, entry = isProtected(fn)
        if hit then
            fireAlert(LEVEL.WARN, "coroutine.wrap",
                ("wrap on protected [%s]"):format(entry.name))
        end
        return realWrap(fn)
    end

    print("[ANTISPY] coroutine monitor: active")
end

local function snapshotNatives()
    local paths = {
        {"string","dump"},  {"string","find"},   {"string","match"},
        {"string","byte"},  {"string","sub"},    {"string","gmatch"},
        {"string","gsub"},  {"string","format"},
        {"debug","getupvalue"}, {"debug","sethook"}, {"debug","getinfo"},
        {"debug","getlocal"},
        {"os","clock"},     {"os","time"},        {"os","difftime"},
        {"coroutine","resume"}, {"coroutine","wrap"}, {"coroutine","create"},
        {"coroutine","yield"},  {"coroutine","status"},
        {"table","unpack"}, {"table","concat"},   {"table","insert"},
        {"math","random"},  {"math","randomseed"},
    }
    local flat = {
        "rawget","rawset","rawequal","rawlen",
        "tostring","tonumber","type","pcall","xpcall",
        "error","assert","pairs","ipairs","next","select",
        "setmetatable","getmetatable","loadstring","require",
        "print","warn","load",
    }
    for _, p in ipairs(paths) do
        local lib = _G[p[1]]
        if type(lib) == "table" then
            local fn = lib[p[2]]
            if type(fn) == "function" then
                NativeSnap[p[1].."."..p[2]] = {addr=tostring(fn), ref=fn}
            end
        end
    end
    for _, name in ipairs(flat) do
        local fn = _G[name]
        if type(fn) == "function" then
            NativeSnap[name] = {addr=tostring(fn), ref=fn}
        end
    end
    local n=0; for _ in pairs(NativeSnap) do n=n+1 end
    print(("[ANTISPY] native snapshot: %d functions indexed"):format(n))
end

local function scanNatives()
    local tampered = {}
    for key, snap in pairs(NativeSnap) do
        local fn
        local dot = key:find(".", 1, true)
        if dot then
            local lib = _G[key:sub(1, dot-1)]
            if type(lib) == "table" then fn = lib[key:sub(dot+1)] end
        else
            fn = _G[key]
        end
        if type(fn) == "function" and tostring(fn) ~= snap.addr then
            tampered[#tampered+1] = {key=key, was=snap.addr, now=tostring(fn)}
        end
    end
    return tampered
end

local function scanFns()
    local violations = {}
    for _, entry in ipairs(Protected) do
        if entry.fp and type(entry.original) == "function" then
            local cur = fingerprint(entry.original)
            if cur then
                local diverged, reason = fpDiff(entry.fp, cur)
                if diverged then
                    violations[#violations+1] = {
                        name   = entry.name,
                        reason = reason,
                        entry  = entry,
                    }
                end
            end
        end
    end
    return violations
end

local function guardTable(tbl, name, keys)
    if type(tbl) ~= "table" then return end
    local keySet  = {}
    local catchAll = true
    if keys and #keys > 0 then
        catchAll = false
        for _, k in ipairs(keys) do keySet[k] = true end
    end

    local mt = (EXEC.getrawmetatable and EXEC.getrawmetatable(tbl))
            or getmetatable(tbl) or {}
    local origIdx  = rawget(mt, "__index")
    local origNidx = rawget(mt, "__newindex")

    mt.__index = function(t, k)
        if (catchAll or keySet[k]) and not callerOk() then
            fireAlert(LEVEL.WARN, name..":read",
                ("key %q accessed"):format(tostring(k)))
        end
        if type(origIdx) == "function" then return origIdx(t, k)
        elseif type(origIdx) == "table" then return origIdx[k]
        else return rawget(t, k) end
    end

    mt.__newindex = function(t, k, v)
        if (catchAll or keySet[k]) and not callerOk() then
            fireAlert(LEVEL.CRIT, name..":write",
                ("key %q = %s"):format(tostring(k), tostring(v):sub(1, 72)))
        end
        if type(origNidx) == "function" then origNidx(t, k, v)
        else rawset(t, k, v) end
    end

    if EXEC.setrawmetatable then
        pcall(EXEC.setrawmetatable, tbl, mt)
    else
        pcall(setmetatable, tbl, mt)
    end
    if EXEC.setreadonly then 
        pcall(function() EXEC.setreadonly(mt, true) end)
    end
    print(("[ANTISPY] table guard attached: %s"):format(name))
end

local function poisonUpvalues(fn, name)
    if not EXEC.islclosure or not EXEC.islclosure(fn) then return end
    if type(debug.setupvalue) ~= "function" then return end
    if not EXEC.getupvalues then return end
    local ups = EXEC.getupvalues(fn)
    for i, v in ipairs(ups) do
        if type(v) == "table" then
            local real = v
            local poison = setmetatable({}, {
                __index = function(_, k)
                    fireAlert(LEVEL.CRIT, name..":upval_read",
                        ("upval[%d].%q tapped by spy"):format(i, tostring(k)))
                    return rawget(real, k)
                end,
                __newindex = function(_, k, val)
                    fireAlert(LEVEL.CRIT, name..":upval_write",
                        ("upval[%d].%q written by spy = %s"):format(
                            i, tostring(k), tostring(val):sub(1,40)))
                    rawset(real, k, val)
                end,
                __len = function()
                    fireAlert(LEVEL.WARN, name..":upval_len",
                        ("upval[%d] length probed"):format(i))
                    return #real
                end,
                __pairs = function()
                    fireAlert(LEVEL.CRIT, name..":upval_pairs",
                        ("upval[%d] enumerated by spy"):format(i))
                    return next, real, nil
                end,
            })
            pcall(debug.setupvalue, fn, i, poison)
        end
    end
end

local function startHeartbeat(interval)
    interval = interval or 0.5
    if ScanThr then pcall(task.cancel, ScanThr) end
    ScanThr = task.spawn(function()
        while Active do
            task.wait(interval)
            for _, t in ipairs(scanNatives()) do
                fireAlert(LEVEL.CRIT, "native:"..t.key,
                    ("HOOKED — was %s now %s"):format(t.was:sub(-10), t.now:sub(-10)))
            end
            for _, v in ipairs(scanFns()) do
                fireAlert(LEVEL.CRIT, "fn:"..v.name, v.reason)
                if v.entry.killOnHook then
                    error("[ANTISPY] integrity kill: " .. v.name)
                end
            end
        end
    end)
    print(("[ANTISPY] heartbeat: %.2fs interval"):format(interval))
end

local AntiSpy = {_VERSION = "2.1.0"}

function AntiSpy.protect(fn, name, opts)
    assert(type(fn) == "function", "[ANTISPY] protect: function expected")
    opts = opts or {}
    local entry = {
        name       = name or tostring(fn),
        original   = fn,
        wrapped    = nil,
        fp         = fingerprint(fn),
        killOnHook = opts.killOnHook or false,
    }
    if EXEC.newcclosure then
        local ok, w = pcall(EXEC.newcclosure, fn)
        if ok and type(w) == "function" then entry.wrapped = w end
    end
    Protected[#Protected+1] = entry
    if opts.poisonUpvalues then poisonUpvalues(fn, entry.name) end
    print(("[ANTISPY] protected: %s  (newcc=%s  hash=%s  byteLen=%s)"):format(
        entry.name,
        tostring(entry.wrapped ~= nil),
        tostring(entry.fp and entry.fp.byteHash or "n/a"),
        tostring(entry.fp and entry.fp.byteLen  or "n/a")))
    return entry.wrapped or fn
end

function AntiSpy.watch(tbl, name, keys)
    assert(type(tbl) == "table", "[ANTISPY] watch: table expected")
    guardTable(tbl, name or tostring(tbl), keys)
end

function AntiSpy.onAlert(cb)
    assert(type(cb) == "function", "[ANTISPY] onAlert: function expected")
    AlertCBs[#AlertCBs+1] = cb
end

function AntiSpy.scan()
    local nat = scanNatives()
    local fns = scanFns()
    print(("[ANTISPY:SCAN] native_hooks=%d  fn_violations=%d"):format(#nat, #fns))
    for _, t in ipairs(nat) do
        print(("  [NATIVE] %s  was=%s  now=%s"):format(t.key, t.was, t.now))
    end
    for _, v in ipairs(fns) do
        print(("  [FN-TAMPER] %s : %s"):format(v.name, v.reason))
    end
    return {native=nat, fns=fns}
end

function AntiSpy.report()
    local n = #AlertLog
    local c = {[1]=0, [2]=0, [3]=0}
    for _, e in ipairs(AlertLog) do c[e.level] = c[e.level]+1 end
    local nsnap=0; for _ in pairs(NativeSnap) do nsnap=nsnap+1 end
    print("\n╔══ ANTISPY REPORT ═══════════════════════════════════╗")
    print(("║  Version   : %s"):format(AntiSpy._VERSION))
    print(("║  Alerts    : %d  (INFO=%d  WARN=%d  CRIT=%d)"):format(n,c[1],c[2],c[3]))
    print(("║  Protected : %d functions"):format(#Protected))
    print(("║  Natives   : %d snapshots"):format(nsnap))
    print(("║  Heartbeat : %s"):format(tostring(Active)))
    if n > 0 then
        print("║  ── Last 20 alerts ──────────────────────────────────")
        for i = math.max(1,n-19), n do
            local e = AlertLog[i]
            print(("║  [%s][%.4f] %s | %s"):format(e.tag, e.t, e.src, e.detail))
        end
    end
    print("╚══════════════════════════════════════════════════════╝")
end

function AntiSpy.stop()
    Active = false
    if ScanThr then pcall(task.cancel, ScanThr); ScanThr=nil end
    print("[ANTISPY] stopped — shields down")
end

function AntiSpy.start(opts)
    opts = opts or {}
    if Active then print("[ANTISPY] already active"); return AntiSpy end
    Active = true

    print(("[ANTISPY] v%s — initializing"):format(AntiSpy._VERSION))
    snapshotNatives()
    shieldDebug()
    shieldHookfunction()
    shieldStringDump()
    shieldExecAPIs()
    shieldCoroutines()

    if opts.guardG then
        guardTable(_G, "_G", opts.guardGKeys)
    end
    if opts.guardGenv and type(getgenv) == "function" then
        guardTable(getgenv(), "genv", opts.guardGenvKeys)
    end

    startHeartbeat(opts.interval or 0.5)
    print("[ANTISPY] armed — 8 shields online")
    return AntiSpy
end

if type(getgenv) == "function" then
    getgenv().AntiSpy = AntiSpy
end

if type(getgenv) == "function" then
    AntiSpy.start()
else
    print("[ANTISPY] Warning: getgenv not available, AntiSpy stored locally")
    _G.AntiSpy = AntiSpy
end

print([[
  
  ANTISPY v2.1.0 — USAGE
  ═══════════════════════════════════════════════════════

  local AS = getgenv().AntiSpy

  PROTECT A FUNCTION:
    local myFn = function() return "secret data" end
    myFn = AS.protect(myFn, "myFn", {
        killOnHook     = false,
        poisonUpvalues = true,
    })

  WATCH A TABLE (all keys):
    AS.watch(myTable, "myTable")

  WATCH A TABLE (specific keys only):
    AS.watch(myTable, "myTable", {"password", "token"})

  ALERT CALLBACK:
    AS.onAlert(function(e)
        if e.level == 3 then
            print("CRIT: " .. e.src .. " | " .. e.detail)
        end
    end)

  MANUAL SCAN:
    AS.scan()

  FULL REPORT:
    AS.report()

  STOP:
    AS.stop()

  SHIELD LAYERS:
    1. debug.getupvalue / sethook / getinfo / getlocal / getfenv
    2. hookfunction meta-interceptor
    3. string.dump extraction block
    4. getupvalues / getconstants / getprotos / decompile / clonefunction
    5. coroutine foreign-thread monitor
    6. table metatable guardian (watch)
    7. upvalue poisoning (honeypot metatables)
    8. 500ms native + function integrity heartbeat
  ═══════════════════════════════════════════════════════
]])
