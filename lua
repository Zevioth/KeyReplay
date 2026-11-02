--[[
    FRAMEPLAY - CAMERA KEYFRAME EDITOR (UPGRADED)
    ------------------------------------------------------------------
    One LocalScript. Place in StarterPlayer > StarterPlayerScripts.

    PC: WASD move, E/Q pedestal, RMB drag look, Shift speed boost,
        mouse wheel speed/dolly, Space play/pause, Delete remove,
        Ctrl+C/V copy/paste, Ctrl+D duplicate, Ctrl+Z/Y undo/redo,
        Left/Right arrows step one frame, Esc stop playback.
    Mobile: independent joystick + look touches, UP/DOWN hold buttons.
    Chat: /replay or /frameplay hides/shows the editor.

    Project export is camera-animation JSON data. It does not export MP4.
]]

---------------------------------------------------------------------
-- SERVICES / SINGLE-INSTANCE GUARD
---------------------------------------------------------------------
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
if not player then
    warn("[FramePlay] This must run as a client LocalScript.")
    return
end

local playerGui = player:WaitForChild("PlayerGui")
local shutdownSignal = playerGui:FindFirstChild("FramePlayShutdownSignal")
if not shutdownSignal then
    shutdownSignal = Instance.new("BindableEvent")
    shutdownSignal.Name = "FramePlayShutdownSignal"
    shutdownSignal.Parent = playerGui
end
pcall(function() shutdownSignal:Fire() end)

local oldGui = playerGui:FindFirstChild("FramePlayGui")
if oldGui then oldGui:Destroy() end

local connections = {}
local markerConnections = {}
local listConnections = {}
local temporaryConnections = {}
local cleanedUp = false
local function connect(signal, callback, bucket)
    local connection = signal:Connect(callback)
    table.insert(bucket or connections, connection)
    return connection
end
local function disconnectBucket(bucket)
    for _, connection in ipairs(bucket) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(bucket)
end
local function disconnectTracked(connection, bucket)
    if not connection then return end
    pcall(function() connection:Disconnect() end)
    for index = #bucket, 1, -1 do
        if bucket[index] == connection then table.remove(bucket, index); break end
    end
end

local isTouchDevice = UserInputService.TouchEnabled
local clock = os.clock

---------------------------------------------------------------------
-- MONOCHROME PALETTE
---------------------------------------------------------------------
local COLORS = {
    background = Color3.fromRGB(16, 16, 16),
    toolbar = Color3.fromRGB(24, 24, 24),
    panel = Color3.fromRGB(32, 32, 32),
    panel2 = Color3.fromRGB(41, 41, 41),
    input = Color3.fromRGB(21, 21, 21),
    button = Color3.fromRGB(53, 53, 53),
    buttonHover = Color3.fromRGB(68, 68, 68),
    border = Color3.fromRGB(69, 69, 69),
    divider = Color3.fromRGB(48, 48, 48),
    muted = Color3.fromRGB(160, 160, 160),
    secondary = Color3.fromRGB(197, 197, 197),
    text = Color3.fromRGB(242, 242, 242),
    selected = Color3.fromRGB(96, 96, 96),
    active = Color3.fromRGB(218, 218, 218),
    white = Color3.fromRGB(255, 255, 255),
}

---------------------------------------------------------------------
-- UTILITIES
---------------------------------------------------------------------
local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end
local function round(value, places)
    local m = 10 ^ (places or 2)
    return math.floor(value * m + 0.5) / m
end
local function finiteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end
local function safeText(value, maxLength)
    value = tostring(value or "")
    value = value:gsub("[%c]", " ")
    if #value > (maxLength or 64) then value = value:sub(1, maxLength or 64) end
    return value
end
local function copyVector3(v)
    return Vector3.new(v.X, v.Y, v.Z)
end
local function copyKeyframe(k)
    return {
        id = k.id,
        time = k.time,
        cframe = k.cframe,
        fov = k.fov,
        easing = k.easing or "Smooth",
        interpolation = k.interpolation or "Linear",
    }
end
local function copyKeyframes(source)
    local result = {}
    for _, k in ipairs(source or {}) do result[#result + 1] = copyKeyframe(k) end
    return result
end
local function makeFrame(parent, name, size, position, color, z)
    local frame = Instance.new("Frame")
    frame.Name = name or "Frame"
    frame.Size = size or UDim2.fromScale(1, 1)
    frame.Position = position or UDim2.fromOffset(0, 0)
    frame.BackgroundColor3 = color or COLORS.panel
    frame.BorderSizePixel = 0
    frame.ZIndex = z or 1
    frame.Parent = parent
    return frame
end
local function makeCorner(parent, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 4)
    corner.Parent = parent
    return corner
end
local function makeStroke(parent, color, thickness, transparency)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color or COLORS.border
    stroke.Thickness = thickness or 1
    stroke.Transparency = transparency or 0
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = parent
    return stroke
end
local function makePadding(parent, l, t, r, b)
    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, l or 6)
    padding.PaddingTop = UDim.new(0, t or 6)
    padding.PaddingRight = UDim.new(0, r or 6)
    padding.PaddingBottom = UDim.new(0, b or 6)
    padding.Parent = parent
    return padding
end
local function makeLabel(parent, text, size, position, textSize, z, alignment)
    local label = Instance.new("TextLabel")
    label.Size = size
    label.Position = position or UDim2.fromOffset(0, 0)
    label.BackgroundTransparency = 1
    label.BorderSizePixel = 0
    label.Text = text or ""
    label.TextColor3 = COLORS.text
    label.Font = Enum.Font.Gotham
    label.TextSize = textSize or 12
    label.TextXAlignment = alignment or Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.ZIndex = z or 1
    label.Parent = parent
    return label
end
local function makeButton(parent, text, size, position, z)
    local button = Instance.new("TextButton")
    button.Size = size
    button.Position = position or UDim2.fromOffset(0, 0)
    button.BackgroundColor3 = COLORS.button
    button.TextColor3 = COLORS.text
    button.Font = Enum.Font.GothamMedium
    button.TextSize = isTouchDevice and 11 or 13
    button.Text = text or ""
    button.AutoButtonColor = true
    button.BorderSizePixel = 0
    button.ZIndex = z or 1
    button.Parent = parent
    makeCorner(button, 4)
    return button
end
local function makeTextBox(parent, placeholder, size, position, z)
    local box = Instance.new("TextBox")
    box.Size = size
    box.Position = position or UDim2.fromOffset(0, 0)
    box.BackgroundColor3 = COLORS.input
    box.TextColor3 = COLORS.text
    box.PlaceholderColor3 = COLORS.muted
    box.PlaceholderText = placeholder or ""
    box.Font = Enum.Font.Gotham
    box.TextSize = isTouchDevice and 11 or 13
    box.Text = ""
    box.ClearTextOnFocus = false
    box.BorderSizePixel = 0
    box.ZIndex = z or 1
    box.Parent = parent
    makeCorner(box, 3)
    makeStroke(box, COLORS.border, 1)
    return box
end
local function makeDivider(parent, y, z)
    local line = makeFrame(parent, "Divider", UDim2.new(1, 0, 0, 1), UDim2.new(0, 0, 0, y), COLORS.divider, z or 1)
    return line
end

---------------------------------------------------------------------
-- EDITOR / CAMERA STATE
---------------------------------------------------------------------
local editorOpen = false
local editorHidden = false
local isPlaying = false
local isPaused = false
local countdownActive = false
local countdownToken = 0
local currentTime = 0
local playbackSpeed = 1
local duration = 10
local loopPlayback = false
local loopRegionEnabled = false
local loopRegionStart = 0
local loopRegionEnd = 10
local reversePlayback = false
local camMoveSpeed = 40
local camSensitivity = 0.2
local defaultFOV = 70
local currentFOV = 70
local timelineZoom = 1
local snapEnabled = true
local snapFPS = 30
local timelineSnapFrame = 1 / 30
local easingDefault = "Smooth"
local selectedKeyframe = nil
local selectedIds = {}
local keyframeIdCounter = 0
local copiedKeyframes = {}
local currentShotIndex = 1
local bookmarks = {}
local selectedBookmark = 0
local cameraModeIndex = 1
local CAMERA_MODES = { "Free", "Dolly", "Truck", "Pan", "Tilt", "Pedestal", "Orbit" }
local cameraMode = CAMERA_MODES[cameraModeIndex]
local orbitEnabled = false
local orbitTarget = Vector3.new(0, 0, 0)
local orbitDistance = 24
local orbitYaw = 0
local orbitPitch = 0
local lookAtEnabled = false
local lookAtTarget = Vector3.new(0, 0, 0)
local showPath = false
local guideSettings = { thirds = false, center = false, safe169 = false, safe43 = false, safe235 = false }
local countdownSeconds = 3
local freeCamCFrame = CFrame.new(0, 5, 12)
local moveState = { forward = false, backward = false, left = false, right = false, up = false, down = false }
local shiftHeld = false
local ctrlHeld = false
local rightMouseDown = false
local touchPositions = {}
local joystickInput = nil
local joystickDir = Vector3.zero
local lookInput = nil
local lastLookPosition = nil
local upHeldInput = nil
local downHeldInput = nil

local function newShot(name)
    return {
        name = name or "Shot",
        cameraCFrame = freeCamCFrame,
        keyframes = {},
        duration = 10,
        playbackSpeed = 1,
        loopPlayback = false,
        loopRegionEnabled = false,
        loopRegionStart = 0,
        loopRegionEnd = 10,
        reversePlayback = false,
        easingDefault = "Smooth",
        defaultFOV = 70,
        currentFOV = 70,
        camMoveSpeed = camMoveSpeed,
        camSensitivity = camSensitivity,
        cameraMode = cameraMode,
        orbitEnabled = orbitEnabled,
        orbitDistance = orbitDistance,
        orbitTarget = orbitTarget,
        orbitYaw = orbitYaw,
        orbitPitch = orbitPitch,
        lookAtEnabled = lookAtEnabled,
        lookAtTarget = lookAtTarget,
    }
end
local shots = { newShot("Shot 01") }
local keyframes = shots[1].keyframes

local function saveActiveShot()
    local shot = shots[currentShotIndex]
    if not shot then return end
    shot.keyframes = keyframes
    shot.cameraCFrame = freeCamCFrame
    shot.duration = duration
    shot.playbackSpeed = playbackSpeed
    shot.loopPlayback = loopPlayback
    shot.loopRegionEnabled = loopRegionEnabled
    shot.loopRegionStart = loopRegionStart
    shot.loopRegionEnd = loopRegionEnd
    shot.reversePlayback = reversePlayback
    shot.easingDefault = easingDefault
    shot.defaultFOV = defaultFOV
    shot.currentFOV = currentFOV
    shot.camMoveSpeed = camMoveSpeed
    shot.camSensitivity = camSensitivity
    shot.cameraMode = cameraMode
    shot.orbitEnabled = orbitEnabled
    shot.orbitDistance = orbitDistance
    shot.orbitTarget = orbitTarget
    shot.orbitYaw = orbitYaw
    shot.orbitPitch = orbitPitch
    shot.lookAtEnabled = lookAtEnabled
    shot.lookAtTarget = lookAtTarget
end
local function loadShot(index)
    local shot = shots[index]
    if not shot then return false end
    currentShotIndex = index
    keyframes = shot.keyframes or {}
    if typeof(shot.cameraCFrame) == "CFrame" then freeCamCFrame = shot.cameraCFrame end
    duration = clamp(tonumber(shot.duration) or 10, 0.1, 3600)
    playbackSpeed = clamp(tonumber(shot.playbackSpeed) or 1, 0.05, 20)
    loopPlayback = shot.loopPlayback == true
    loopRegionEnabled = shot.loopRegionEnabled == true
    loopRegionStart = clamp(tonumber(shot.loopRegionStart) or 0, 0, duration)
    loopRegionEnd = clamp(tonumber(shot.loopRegionEnd) or duration, loopRegionStart, duration)
    reversePlayback = shot.reversePlayback == true
    easingDefault = shot.easingDefault or "Smooth"
    defaultFOV = clamp(tonumber(shot.defaultFOV) or 70, 1, 169)
    currentFOV = clamp(tonumber(shot.currentFOV) or defaultFOV, 1, 169)
    camMoveSpeed = clamp(tonumber(shot.camMoveSpeed) or camMoveSpeed, 1, 1000)
    camSensitivity = clamp(tonumber(shot.camSensitivity) or camSensitivity, 0.01, 5)
    if table.find(CAMERA_MODES, shot.cameraMode) then cameraMode = shot.cameraMode; cameraModeIndex = table.find(CAMERA_MODES, cameraMode) end
    orbitEnabled = shot.orbitEnabled == true
    orbitDistance = clamp(tonumber(shot.orbitDistance) or orbitDistance, 1, 10000)
    if typeof(shot.orbitTarget) == "Vector3" then orbitTarget = shot.orbitTarget end
    orbitYaw = tonumber(shot.orbitYaw) or orbitYaw
    orbitPitch = clamp(tonumber(shot.orbitPitch) or orbitPitch, -1.5, 1.5)
    lookAtEnabled = shot.lookAtEnabled == true
    if typeof(shot.lookAtTarget) == "Vector3" then lookAtTarget = shot.lookAtTarget end
    currentTime = clamp(currentTime, 0, duration)
    selectedKeyframe = nil
    selectedIds = {}
    return true
end

---------------------------------------------------------------------
-- CAMERA SNAPSHOTS / RESTORATION
---------------------------------------------------------------------
local camera = Workspace.CurrentCamera
local cameraSnapshot = nil
local function captureCamera(cameraObject)
    if not cameraObject then return nil end
    return {
        camera = cameraObject,
        cameraType = cameraObject.CameraType,
        subject = cameraObject.CameraSubject,
        fov = cameraObject.FieldOfView,
        cframe = cameraObject.CFrame,
    }
end
local function restoreCameraSnapshot()
    local targetCamera = Workspace.CurrentCamera or camera
    local snapshot = cameraSnapshot
    if snapshot and snapshot.camera and snapshot.camera.Parent then
        targetCamera = snapshot.camera
    end
    if targetCamera and snapshot then
        pcall(function()
            targetCamera.CameraType = snapshot.cameraType
            targetCamera.FieldOfView = snapshot.fov
            if snapshot.subject then targetCamera.CameraSubject = snapshot.subject end
            if snapshot.camera and targetCamera == snapshot.camera then
                targetCamera.CFrame = snapshot.cframe
            end
        end)
    end
    cameraSnapshot = nil
    camera = Workspace.CurrentCamera
end
local function forceScriptable()
    camera = Workspace.CurrentCamera or camera
    if camera then
        pcall(function() camera.CameraType = Enum.CameraType.Scriptable end)
    end
end

---------------------------------------------------------------------
-- PLAYBACK GUI STATE RESTORATION
---------------------------------------------------------------------
local savedPlayerGuiStates = nil
local savedCoreGuiStates = {}
local savedTopbarEnabled = true
local savedDevConsoleVisible = false
local hasSavedDevConsoleState = false
local playbackGuiAddedConnection = nil
local coreGuiReassertConnection = nil
local function hidePlaybackGuis()
    if savedPlayerGuiStates then return end
    savedPlayerGuiStates = {}
    savedCoreGuiStates = {}
    local function hideCollector(instance)
        if instance:IsA("LayerCollector") and savedPlayerGuiStates[instance] == nil then
            savedPlayerGuiStates[instance] = instance.Enabled
            instance.Enabled = false
        end
    end
    for _, instance in ipairs(playerGui:GetDescendants()) do hideCollector(instance) end
    playbackGuiAddedConnection = playerGui.DescendantAdded:Connect(function(instance)
        if savedPlayerGuiStates then hideCollector(instance) end
    end)
    local okTop, topValue = pcall(function() return StarterGui:GetCore("TopbarEnabled") end)
    savedTopbarEnabled = okTop and type(topValue) == "boolean" and topValue or true
    local okConsole, consoleValue = pcall(function() return StarterGui:GetCore("DevConsoleVisible") end)
    hasSavedDevConsoleState = okConsole and type(consoleValue) == "boolean"
    if hasSavedDevConsoleState then
        savedDevConsoleVisible = consoleValue
        pcall(function() StarterGui:SetCore("DevConsoleVisible", false) end)
    end
    for _, coreType in ipairs(Enum.CoreGuiType:GetEnumItems()) do
        if coreType.Name ~= "All" then
            local ok, enabled = pcall(function() return StarterGui:GetCoreGuiEnabled(coreType) end)
            if ok then savedCoreGuiStates[coreType] = enabled end
            pcall(function() StarterGui:SetCoreGuiEnabled(coreType, false) end)
        end
    end
    pcall(function() StarterGui:SetCore("TopbarEnabled", false) end)
    local accum = 0
    if coreGuiReassertConnection then coreGuiReassertConnection:Disconnect() end
    coreGuiReassertConnection = RunService.Heartbeat:Connect(function(dt)
        if not savedPlayerGuiStates then return end
        accum += dt
        if accum >= 0.75 then
            accum = 0
            pcall(function() StarterGui:SetCore("TopbarEnabled", false) end)
        end
    end)
end
local function restorePlaybackGuis()
    if not savedPlayerGuiStates then return end
    if playbackGuiAddedConnection then playbackGuiAddedConnection:Disconnect(); playbackGuiAddedConnection = nil end
    if coreGuiReassertConnection then coreGuiReassertConnection:Disconnect(); coreGuiReassertConnection = nil end
    for instance, wasEnabled in pairs(savedPlayerGuiStates) do
        if instance and instance.Parent then pcall(function() instance.Enabled = wasEnabled end) end
    end
    for coreType, wasEnabled in pairs(savedCoreGuiStates) do
        pcall(function() StarterGui:SetCoreGuiEnabled(coreType, wasEnabled) end)
    end
    pcall(function() StarterGui:SetCore("TopbarEnabled", savedTopbarEnabled) end)
    if hasSavedDevConsoleState then pcall(function() StarterGui:SetCore("DevConsoleVisible", savedDevConsoleVisible) end) end
    savedPlayerGuiStates = nil
    savedCoreGuiStates = {}
    hasSavedDevConsoleState = false
end

---------------------------------------------------------------------
-- EASING / INTERPOLATION
---------------------------------------------------------------------
local EASING_MODES = {
    "Linear", "Smooth", "SineIn", "SineOut", "SineInOut",
    "QuadIn", "QuadOut", "QuadInOut", "CubicIn", "CubicOut", "CubicInOut",
    "QuartIn", "QuartOut", "QuartInOut", "ExpoIn", "ExpoOut", "ExpoInOut",
    "CircIn", "CircOut", "CircInOut", "BackIn", "BackOut", "BackInOut",
    "ElasticIn", "ElasticOut", "BounceIn", "BounceOut",
}
local INTERPOLATIONS = { "Linear", "Smooth", "Cubic", "Bezier", "CatmullRom" }
local function bounceOut(t)
    local n, d = 7.5625, 2.75
    if t < 1 / d then return n * t * t end
    if t < 2 / d then t -= 1.5 / d; return n * t * t + 0.75 end
    if t < 2.5 / d then t -= 2.25 / d; return n * t * t + 0.9375 end
    t -= 2.625 / d
    return n * t * t + 0.984375
end
local function easeValue(t, mode)
    t = clamp(t, 0, 1)
    local pi = math.pi
    if mode == "Linear" then return t
    elseif mode == "Smooth" then return t * t * (3 - 2 * t)
    elseif mode == "SineIn" then return 1 - math.cos(t * pi / 2)
    elseif mode == "SineOut" then return math.sin(t * pi / 2)
    elseif mode == "SineInOut" then return -(math.cos(pi * t) - 1) / 2
    elseif mode == "QuadIn" then return t * t
    elseif mode == "QuadOut" then return 1 - (1 - t) * (1 - t)
    elseif mode == "QuadInOut" then return t < 0.5 and 2 * t * t or 1 - ((-2 * t + 2) ^ 2) / 2
    elseif mode == "CubicIn" then return t ^ 3
    elseif mode == "CubicOut" then return 1 - (1 - t) ^ 3
    elseif mode == "CubicInOut" then return t < 0.5 and 4 * t ^ 3 or 1 - ((-2 * t + 2) ^ 3) / 2
    elseif mode == "QuartIn" then return t ^ 4
    elseif mode == "QuartOut" then return 1 - (1 - t) ^ 4
    elseif mode == "QuartInOut" then return t < 0.5 and 8 * t ^ 4 or 1 - ((-2 * t + 2) ^ 4) / 2
    elseif mode == "ExpoIn" then return t == 0 and 0 or 2 ^ (10 * t - 10)
    elseif mode == "ExpoOut" then return t == 1 and 1 or 1 - 2 ^ (-10 * t)
    elseif mode == "ExpoInOut" then
        if t == 0 or t == 1 then return t end
        return t < 0.5 and 2 ^ (20 * t - 10) / 2 or (2 - 2 ^ (-20 * t + 10)) / 2
    elseif mode == "CircIn" then return 1 - math.sqrt(math.max(0, 1 - t * t))
    elseif mode == "CircOut" then return math.sqrt(math.max(0, 1 - (t - 1) ^ 2))
    elseif mode == "CircInOut" then
        if t < 0.5 then return (1 - math.sqrt(math.max(0, 1 - (2 * t) ^ 2))) / 2 end
        return (math.sqrt(math.max(0, 1 - (-2 * t + 2) ^ 2)) + 1) / 2
    elseif mode == "BackIn" then local c = 1.70158; return (c + 1) * t ^ 3 - c * t ^ 2
    elseif mode == "BackOut" then local c = 1.70158; return 1 + (c + 1) * (t - 1) ^ 3 + c * (t - 1) ^ 2
    elseif mode == "BackInOut" then
        local c = 1.70158 * 1.525
        if t < 0.5 then return ((2 * t) ^ 2 * ((c + 1) * 2 * t - c)) / 2 end
        return (((2 * t - 2) ^ 2 * ((c + 1) * (2 * t - 2) + c)) + 2) / 2
    elseif mode == "ElasticIn" then
        if t == 0 or t == 1 then return t end
        return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * (2 * pi / 3))
    elseif mode == "ElasticOut" then
        if t == 0 or t == 1 then return t end
        return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * (2 * pi / 3)) + 1
    elseif mode == "BounceIn" then return 1 - bounceOut(1 - t)
    elseif mode == "BounceOut" then return bounceOut(t) end
    return t
end
local function catmullRom(p0, p1, p2, p3, t)
    local t2, t3 = t * t, t * t * t
    return (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (-p0 + p1 * 3 - p2 * 3 + p3) * t3) * 0.5
end
local function bezier(p0, p1, p2, p3, t)
    local u = 1 - t
    return p0 * (u ^ 3) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t ^ 3)
end
local function sortKeyframes()
    table.sort(keyframes, function(a, b)
        if a.time == b.time then return a.id < b.id end
        return a.time < b.time
    end)
end
local function findKeyframeNear(t, ignoreSet)
    for _, k in ipairs(keyframes) do
        if not (ignoreSet and ignoreSet[k.id]) and math.abs(k.time - t) < 0.001 then return k end
    end
    return nil
end
local function getCameraStateAtTime(t)
    local count = #keyframes
    if count == 0 then return nil, nil end
    if count == 1 or t <= keyframes[1].time then return keyframes[1].cframe, keyframes[1].fov end
    if t >= keyframes[count].time then return keyframes[count].cframe, keyframes[count].fov end
    for index = 1, count - 1 do
        local a, b = keyframes[index], keyframes[index + 1]
        if t >= a.time and t <= b.time then
            local span = math.max(0.000001, b.time - a.time)
            local alpha = clamp((t - a.time) / span, 0, 1)
            alpha = easeValue(alpha, a.easing or easingDefault)
            local mode = a.interpolation or "Linear"
            local pa, pb = a.cframe.Position, b.cframe.Position
            local pos
            if mode == "Bezier" then
                local prev = keyframes[math.max(1, index - 1)].cframe.Position
                local nxt = keyframes[math.min(count, index + 2)].cframe.Position
                local c1 = pa + (pb - prev) / 6
                local c2 = pb - (nxt - pa) / 6
                pos = bezier(pa, c1, c2, pb, alpha)
            elseif mode == "CatmullRom" then
                local p0 = keyframes[math.max(1, index - 1)].cframe.Position
                local p3 = keyframes[math.min(count, index + 2)].cframe.Position
                pos = catmullRom(p0, pa, pb, p3, alpha)
            elseif mode == "Smooth" then
                local smooth = alpha * alpha * (3 - 2 * alpha)
                pos = pa:Lerp(pb, smooth)
            elseif mode == "Cubic" then
                local cubic = easeValue(alpha, "CubicInOut")
                pos = pa:Lerp(pb, cubic)
            else
                pos = pa:Lerp(pb, alpha)
            end
            local rotA = a.cframe - a.cframe.Position
            local rotB = b.cframe - b.cframe.Position
            local rotation = rotA:Lerp(rotB, alpha)
            local cf = CFrame.new(pos) * rotation
            local fov = a.fov + (b.fov - a.fov) * alpha
            return cf, fov
        end
    end
    return keyframes[count].cframe, keyframes[count].fov
end

---------------------------------------------------------------------
-- UNDO / REDO SNAPSHOTS
---------------------------------------------------------------------
local undoStack, redoStack = {}, {}
local HISTORY_LIMIT = 80
local MAX_KEYFRAMES_PER_SHOT = 1000
local function cloneShot(shot)
    return {
        name = shot.name,
        cameraCFrame = shot.cameraCFrame,
        keyframes = copyKeyframes(shot.keyframes),
        duration = shot.duration,
        playbackSpeed = shot.playbackSpeed,
        loopPlayback = shot.loopPlayback,
        loopRegionEnabled = shot.loopRegionEnabled,
        loopRegionStart = shot.loopRegionStart,
        loopRegionEnd = shot.loopRegionEnd,
        reversePlayback = shot.reversePlayback,
        easingDefault = shot.easingDefault,
        defaultFOV = shot.defaultFOV,
        currentFOV = shot.currentFOV,
        camMoveSpeed = shot.camMoveSpeed,
        camSensitivity = shot.camSensitivity,
        cameraMode = shot.cameraMode,
        orbitEnabled = shot.orbitEnabled,
        orbitDistance = shot.orbitDistance,
        orbitTarget = shot.orbitTarget,
        orbitYaw = shot.orbitYaw,
        orbitPitch = shot.orbitPitch,
        lookAtEnabled = shot.lookAtEnabled,
        lookAtTarget = shot.lookAtTarget,
    }
end
local function captureState()
    saveActiveShot()
    local shotCopies = {}
    for _, shot in ipairs(shots) do shotCopies[#shotCopies + 1] = cloneShot(shot) end
    local bookmarkCopies = {}
    for _, mark in ipairs(bookmarks) do
        bookmarkCopies[#bookmarkCopies + 1] = { name = mark.name, cframe = mark.cframe, fov = mark.fov }
    end
    return {
        shots = shotCopies,
        active = currentShotIndex,
        bookmarks = bookmarkCopies,
        duration = duration,
        currentTime = currentTime,
        playbackSpeed = playbackSpeed,
        loopPlayback = loopPlayback,
        loopRegionEnabled = loopRegionEnabled,
        loopRegionStart = loopRegionStart,
        loopRegionEnd = loopRegionEnd,
        reversePlayback = reversePlayback,
        easingDefault = easingDefault,
        defaultFOV = defaultFOV,
        currentFOV = currentFOV,
        timelineZoom = timelineZoom,
        snapEnabled = snapEnabled,
        snapFPS = snapFPS,
    }
end
local function updateUIReferences() end
local function pushUndo()
    undoStack[#undoStack + 1] = captureState()
    if #undoStack > HISTORY_LIMIT then table.remove(undoStack, 1) end
    table.clear(redoStack)
end
local function restoreStateSnapshot(snapshot)
    shots = {}
    for _, shot in ipairs(snapshot.shots) do shots[#shots + 1] = cloneShot(shot) end
    bookmarks = {}
    for _, mark in ipairs(snapshot.bookmarks or {}) do bookmarks[#bookmarks + 1] = { name = mark.name, cframe = mark.cframe, fov = mark.fov } end
    currentShotIndex = clamp(snapshot.active or 1, 1, #shots)
    loadShot(currentShotIndex)
    currentTime = clamp(snapshot.currentTime or 0, 0, duration)
    if camera then camera.CFrame = freeCamCFrame; camera.FieldOfView = currentFOV end
    timelineZoom = snapshot.timelineZoom or timelineZoom
    snapEnabled = snapshot.snapEnabled ~= false
    snapFPS = snapshot.snapFPS or 30
    timelineSnapFrame = 1 / snapFPS
    selectedKeyframe = nil
    selectedIds = {}
    if updateUIReferences then updateUIReferences() end
end
local function undo()
    if #undoStack == 0 then return end
    redoStack[#redoStack + 1] = captureState()
    local state = table.remove(undoStack)
    restoreStateSnapshot(state)
end
local function redo()
    if #redoStack == 0 then return end
    undoStack[#undoStack + 1] = captureState()
    local state = table.remove(redoStack)
    restoreStateSnapshot(state)
end

---------------------------------------------------------------------
-- GUI DECLARATIONS / REFRESH FORWARD DECLARATIONS
---------------------------------------------------------------------
local UI = {}
local refreshKeyframeList, refreshTimelineMarkers, refreshSelectedPanel
local refreshRuler, updatePlayheadVisual, updateTimeDisplays, refreshPathVisualization
local seekTo, updateShotControls, updateBookmarkControls, updateGuideVisibility
local setStatus
local renderConnection
local pathFolder
local resetJoystick

---------------------------------------------------------------------
-- KEYFRAME OPERATIONS
---------------------------------------------------------------------
local function selectKeyframe(k, additive)
    if not k then
        if not additive then selectedIds = {}; selectedKeyframe = nil end
    elseif additive then
        if selectedIds[k.id] then
            selectedIds[k.id] = nil
            if selectedKeyframe == k then
                selectedKeyframe = nil
                for _, candidate in ipairs(keyframes) do
                    if selectedIds[candidate.id] then selectedKeyframe = candidate; break end
                end
            end
        else
            selectedIds[k.id] = true
            selectedKeyframe = k
        end
    else
        selectedIds = { [k.id] = true }
        selectedKeyframe = k
    end
    if refreshKeyframeList then refreshKeyframeList() end
    if refreshTimelineMarkers then refreshTimelineMarkers() end
    if refreshSelectedPanel then refreshSelectedPanel() end
end
local function addKeyframe(t, cf, fov)
    if #keyframes >= MAX_KEYFRAMES_PER_SHOT then
        setStatus("This shot reached the 1,000-keyframe limit.")
        return false
    end
    t = clamp(t, 0, duration)
    if findKeyframeNear(t) then
        setStatus("A keyframe already exists at that time.")
        return false
    end
    pushUndo()
    keyframeIdCounter += 1
    local k = { id = keyframeIdCounter, time = t, cframe = cf, fov = clamp(fov or currentFOV, 1, 169), easing = easingDefault, interpolation = "Linear" }
    keyframes[#keyframes + 1] = k
    sortKeyframes()
    selectKeyframe(k)
    if refreshPathVisualization then refreshPathVisualization() end
    return true
end
local function removeKeyframesById(idSet)
    local kept = {}
    for _, k in ipairs(keyframes) do if not idSet[k.id] then kept[#kept + 1] = k end end
    keyframes = kept
    shots[currentShotIndex].keyframes = keyframes
end
local function deleteSelectedKeyframes()
    if not selectedKeyframe and next(selectedIds) == nil then return end
    pushUndo()
    local idSet = {}
    for id in pairs(selectedIds) do idSet[id] = true end
    if selectedKeyframe then idSet[selectedKeyframe.id] = true end
    removeKeyframesById(idSet)
    selectedKeyframe = nil
    selectedIds = {}
    if refreshKeyframeList then refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshPathVisualization() end
end
local function nearestKeyframeToTime(t)
    local best, distance = nil, math.huge
    for _, k in ipairs(keyframes) do
        local d = math.abs(k.time - t)
        if d < distance then best, distance = k, d end
    end
    return best
end
local function duplicateSelectedKeyframes()
    if not selectedKeyframe then return end
    local sourceSet = {}
    for id in pairs(selectedIds) do sourceSet[id] = true end
    sourceSet[selectedKeyframe.id] = true
    local sources = {}
    for _, k in ipairs(keyframes) do if sourceSet[k.id] then sources[#sources + 1] = k end end
    if #sources == 0 then return end
    if #keyframes + #sources > MAX_KEYFRAMES_PER_SHOT then
        setStatus("Duplicate cancelled: this shot would exceed 1,000 keyframes.")
        return
    end
    table.sort(sources, function(a, b) return a.time < b.time end)
    local earliest = sources[1].time
    local offset = math.max(1 / math.max(1, snapFPS), 0.1)
    local candidates = {}
    for _, source in ipairs(sources) do
        candidates[#candidates + 1] = { source = source, time = source.time + offset }
    end
    local candidateTimes = {}
    for _, candidate in ipairs(candidates) do
        candidate.time = clamp(candidate.time, 0, duration)
        if findKeyframeNear(candidate.time) then
            setStatus("Duplicate cancelled: destination contains a keyframe.")
            return
        end
        for _, reserved in ipairs(candidateTimes) do
            if math.abs(reserved - candidate.time) < 0.001 then
                setStatus("Duplicate cancelled: copied keyframes would overlap.")
                return
            end
        end
        candidateTimes[#candidateTimes + 1] = candidate.time
    end
    pushUndo()
    selectedIds = {}
    selectedKeyframe = nil
    for _, candidate in ipairs(candidates) do
        keyframeIdCounter += 1
        local newK = copyKeyframe(candidate.source)
        newK.id = keyframeIdCounter
        newK.time = candidate.time
        keyframes[#keyframes + 1] = newK
        selectedIds[newK.id] = true
        selectedKeyframe = newK
    end
    sortKeyframes()
    if refreshKeyframeList then refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshPathVisualization() end
end
local function moveSelectedGroup(delta)
    local idSet = {}
    for id in pairs(selectedIds) do idSet[id] = true end
    if selectedKeyframe then idSet[selectedKeyframe.id] = true end
    local moving = {}
    local minTime, maxTime = math.huge, -math.huge
    for _, k in ipairs(keyframes) do
        if idSet[k.id] then
            moving[#moving + 1] = k
            minTime = math.min(minTime, k.time)
            maxTime = math.max(maxTime, k.time)
        end
    end
    if #moving == 0 then return false end
    delta = clamp(delta, -minTime, duration - maxTime)
    local ignored = idSet
    for _, k in ipairs(moving) do
        if findKeyframeNear(k.time + delta, ignored) then return false end
    end
    for _, k in ipairs(moving) do k.time += delta end
    sortKeyframes()
    return true
end
local function clearAllKeyframes()
    if #keyframes == 0 then return end
    pushUndo()
    keyframes = {}
    shots[currentShotIndex].keyframes = keyframes
    selectedKeyframe = nil
    selectedIds = {}
    if refreshKeyframeList then refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshPathVisualization() end
end

---------------------------------------------------------------------
-- UI BUILD
---------------------------------------------------------------------
local function buildUI()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "FramePlayGui"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    pcall(function() screenGui.ScreenInsets = Enum.ScreenInsets.None end)
    pcall(function() screenGui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None end)
    screenGui.DisplayOrder = 1000
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = playerGui

    local root = makeFrame(screenGui, "Root", UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0), COLORS.background, 1)
    root.AnchorPoint = Vector2.new(0, 0)
    root.Position = UDim2.fromOffset(0, 0)
    root.BackgroundTransparency = 1
    root.Visible = false
    root.ClipsDescendants = true

    local touchCatcher = Instance.new("TextButton")
    touchCatcher.Name = "ViewportTouchCatcher"
    touchCatcher.Size = UDim2.fromScale(1, 1)
    touchCatcher.Position = UDim2.fromScale(0, 0)
    touchCatcher.BackgroundTransparency = 1
    touchCatcher.Text = ""
    touchCatcher.AutoButtonColor = false
    touchCatcher.Active = true
    touchCatcher.ZIndex = 1
    touchCatcher.Parent = root

    local toolbarHeight = isTouchDevice and 38 or 46
    local toolbar = makeFrame(root, "Toolbar", UDim2.new(1, 0, 0, toolbarHeight), UDim2.fromOffset(0, 0), COLORS.toolbar, 5)
    toolbar.Active = true
    makeStroke(toolbar, COLORS.border, 1)
    local title = makeLabel(toolbar, "FRAMEPLAY", UDim2.new(0, isTouchDevice and 94 or 130, 1, 0), UDim2.fromOffset(12, 0), isTouchDevice and 12 or 15, 6)
    title.Font = Enum.Font.GothamBold
    local toolbarScroll = Instance.new("ScrollingFrame")
    toolbarScroll.Name = "ToolbarActions"
    toolbarScroll.Position = UDim2.new(0, isTouchDevice and 100 or 140, 0, 0)
    toolbarScroll.Size = UDim2.new(1, -(isTouchDevice and 104 or 146), 1, 0)
    toolbarScroll.BackgroundTransparency = 1
    toolbarScroll.BorderSizePixel = 0
    toolbarScroll.ScrollingDirection = Enum.ScrollingDirection.X
    toolbarScroll.ScrollBarThickness = 0
    toolbarScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
    toolbarScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    toolbarScroll.ZIndex = 6
    toolbarScroll.Parent = toolbar
    local toolbarLayout = Instance.new("UIListLayout")
    toolbarLayout.FillDirection = Enum.FillDirection.Horizontal
    toolbarLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    toolbarLayout.Padding = UDim.new(0, 4)
    toolbarLayout.Parent = toolbarScroll
    local function topButton(text, width)
        local b = makeButton(toolbarScroll, text, UDim2.new(0, width or (isTouchDevice and 48 or 62), 0, isTouchDevice and 28 or 32), nil, 6)
        return b
    end
    local playBtn = topButton("PLAY", 52)
    local pauseBtn = topButton("PAUSE", 58)
    local stopBtn = topButton("STOP", 52)
    local addBtn = topButton("+ KEY", 54)
    local deleteBtn = topButton("- KEY", 54)
    local undoBtn = topButton("UNDO", 54)
    local redoBtn = topButton("REDO", 54)
    local copyBtn = topButton("COPY", 52)
    local pasteBtn = topButton("PASTE", 56)
    local modeBtn = topButton("MODE: FREE", 92)
    local panelBtn = topButton("PANEL", 56)
    local settingsBtn = topButton("SETTINGS", 72)
    local helpBtn = topButton("?", 30)
    local closeBtn = topButton("X", 30)

    local leftPanel = makeFrame(root, "Inspector", UDim2.new(0, 240, 1, -toolbarHeight - 150), UDim2.new(0, 0, 0, toolbarHeight), COLORS.panel, 4)
    leftPanel.Active = true
    makeStroke(leftPanel, COLORS.border, 1)
    local inspectorTitle = makeLabel(leftPanel, "INSPECTOR / KEYFRAMES", UDim2.new(1, -12, 0, 26), UDim2.fromOffset(8, 3), 11, 5)
    inspectorTitle.Font = Enum.Font.GothamBold
    inspectorTitle.TextColor3 = COLORS.muted
    local listFrame = Instance.new("ScrollingFrame")
    listFrame.Name = "KeyframeList"
    listFrame.Position = UDim2.fromOffset(7, 32)
    listFrame.Size = UDim2.new(1, -14, 0, isTouchDevice and 92 or 124)
    listFrame.BackgroundColor3 = COLORS.panel2
    listFrame.BorderSizePixel = 0
    listFrame.ScrollBarThickness = 4
    listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    listFrame.ZIndex = 5
    listFrame.Parent = leftPanel
    makeCorner(listFrame, 3)
    makePadding(listFrame, 4, 4, 4, 4)
    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 3)
    listLayout.Parent = listFrame

    local inspectorScroll = Instance.new("ScrollingFrame")
    inspectorScroll.Name = "InspectorFields"
    inspectorScroll.Position = UDim2.new(0, 7, 0, isTouchDevice and 132 or 164)
    inspectorScroll.Size = UDim2.new(1, -14, 1, -(isTouchDevice and 139 or 171))
    inspectorScroll.BackgroundTransparency = 1
    inspectorScroll.BorderSizePixel = 0
    inspectorScroll.ScrollBarThickness = 3
    inspectorScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    inspectorScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    inspectorScroll.ZIndex = 5
    inspectorScroll.Parent = leftPanel
    local inspectorLayout = Instance.new("UIListLayout")
    inspectorLayout.SortOrder = Enum.SortOrder.LayoutOrder
    inspectorLayout.Padding = UDim.new(0, 4)
    inspectorLayout.Parent = inspectorScroll

    local function fieldRow(labelText, order)
        local row = makeFrame(inspectorScroll, "Field_" .. labelText, UDim2.new(1, 0, 0, 22), nil, COLORS.panel, 5)
        row.LayoutOrder = order
        local label = makeLabel(row, labelText, UDim2.new(0, 54, 1, 0), UDim2.fromOffset(2, 0), 10, 6)
        label.TextColor3 = COLORS.muted
        local box = makeTextBox(row, "0", UDim2.new(1, -60, 1, 0), UDim2.fromOffset(60, 0), 6)
        return box
    end
    local posXBox = fieldRow("POS X", 1)
    local posYBox = fieldRow("POS Y", 2)
    local posZBox = fieldRow("POS Z", 3)
    local rotXBox = fieldRow("ROT X", 4)
    local rotYBox = fieldRow("ROT Y", 5)
    local rotZBox = fieldRow("ROLL / Z", 6)
    local fovBox = fieldRow("FOV", 7)
    local timeBox = fieldRow("TIME", 8)

    local segmentLabel = makeLabel(inspectorScroll, "SEGMENT SETTINGS", UDim2.new(1, 0, 0, 18), nil, 10, 5)
    segmentLabel.LayoutOrder = 9
    segmentLabel.TextColor3 = COLORS.muted
    segmentLabel.Font = Enum.Font.GothamBold
    local segmentEaseBtn = makeButton(inspectorScroll, "EASING: Smooth", UDim2.new(1, 0, 0, 24), nil, 5)
    segmentEaseBtn.LayoutOrder = 10
    local interpolationBtn = makeButton(inspectorScroll, "PATH: Linear", UDim2.new(1, 0, 0, 24), nil, 5)
    interpolationBtn.LayoutOrder = 11
    local applyFieldsBtn = makeButton(inspectorScroll, "APPLY VALUES", UDim2.new(1, 0, 0, 25), nil, 5)
    applyFieldsBtn.LayoutOrder = 12
    local snapCameraBtn = makeButton(inspectorScroll, "SET FROM CAMERA", UDim2.new(1, 0, 0, 25), nil, 5)
    snapCameraBtn.LayoutOrder = 13
    local duplicateBtn = makeButton(inspectorScroll, "DUPLICATE SELECTED", UDim2.new(1, 0, 0, 25), nil, 5)
    duplicateBtn.LayoutOrder = 14
    local deleteSelectedBtn = makeButton(inspectorScroll, "DELETE SELECTED", UDim2.new(1, 0, 0, 25), nil, 5)
    deleteSelectedBtn.LayoutOrder = 15
    local clearAllBtn = makeButton(inspectorScroll, "CLEAR SHOT KEYFRAMES", UDim2.new(1, 0, 0, 25), nil, 5)
    clearAllBtn.LayoutOrder = 16

    local timelineHeight = isTouchDevice and 112 or 154
    local timeline = makeFrame(root, "Timeline", UDim2.new(1, 0, 0, timelineHeight), UDim2.new(0, 0, 1, -timelineHeight), COLORS.toolbar, 4)
    timeline.Active = true
    makeStroke(timeline, COLORS.border, 1)
    local controls = Instance.new("ScrollingFrame")
    controls.Position = UDim2.fromOffset(7, 5)
    controls.Size = UDim2.new(1, -14, 0, isTouchDevice and 25 or 29)
    controls.BackgroundTransparency = 1
    controls.BorderSizePixel = 0
    controls.ScrollingDirection = Enum.ScrollingDirection.X
    controls.ScrollBarThickness = 0
    controls.AutomaticCanvasSize = Enum.AutomaticSize.X
    controls.CanvasSize = UDim2.new(0, 0, 0, 0)
    controls.ZIndex = 5
    controls.Parent = timeline
    local controlsLayout = Instance.new("UIListLayout")
    controlsLayout.FillDirection = Enum.FillDirection.Horizontal
    controlsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    controlsLayout.Padding = UDim.new(0, 4)
    controlsLayout.Parent = controls
    local function controlButton(text, width)
        return makeButton(controls, text, UDim2.new(0, width or 48, 1, 0), nil, 5)
    end
    local prevFrameBtn = controlButton("- FRAME", 64)
    local prevKeyBtn = controlButton("|<", 34)
    local nextKeyBtn = controlButton(">|", 34)
    local nextFrameBtn = controlButton("+ FRAME", 64)
    local restartTimelineBtn = controlButton("RESTART", 64)
    local zoomOutBtn = controlButton("ZOOM -", 56)
    local zoomInBtn = controlButton("ZOOM +", 56)
    local durationBox = makeTextBox(controls, "Duration", UDim2.new(0, 62, 1, 0), nil, 5)
    durationBox.Text = tostring(duration)
    local speedBox = makeTextBox(controls, "Speed", UDim2.new(0, 52, 1, 0), nil, 5)
    speedBox.Text = tostring(playbackSpeed)
    local loopBtn = controlButton("LOOP OFF", 66)
    local loopInBtn = controlButton("SET IN", 48)
    local loopOutBtn = controlButton("SET OUT", 54)
    local regionBtn = controlButton("REGION OFF", 78)
    local reverseBtn = controlButton("REVERSE OFF", 82)
    local snapBtn = controlButton("SNAP 30", 72)
    local timeLabel = makeLabel(controls, "00:00.00 / 00:10.00", UDim2.new(0, 132, 1, 0), nil, 10, 6, Enum.TextXAlignment.Right)

    local trackScroll = Instance.new("ScrollingFrame")
    trackScroll.Name = "TimelineScroll"
    trackScroll.Position = UDim2.new(0, 7, 0, isTouchDevice and 34 or 39)
    trackScroll.Size = UDim2.new(1, -14, 1, -(isTouchDevice and 39 or 45))
    trackScroll.BackgroundColor3 = COLORS.panel2
    trackScroll.BorderSizePixel = 0
    trackScroll.ScrollBarThickness = isTouchDevice and 5 or 7
    trackScroll.ScrollingDirection = Enum.ScrollingDirection.X
    trackScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    trackScroll.ZIndex = 5
    trackScroll.Parent = timeline
    makeCorner(trackScroll, 3)
    local trackCanvas = makeFrame(trackScroll, "TrackCanvas", UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0), COLORS.panel2, 5)
    trackCanvas.Active = true
    local ruler = makeFrame(trackCanvas, "Ruler", UDim2.new(1, 0, 0, 18), UDim2.fromOffset(0, 0), COLORS.panel2, 5)
    local markerLane = makeFrame(trackCanvas, "MarkerLane", UDim2.new(1, 0, 1, -18), UDim2.fromOffset(0, 18), COLORS.panel, 5)
    markerLane.Active = true
    local playhead = makeFrame(markerLane, "Playhead", UDim2.new(0, 2, 1, 0), UDim2.fromOffset(0, 0), COLORS.white, 8)

    local statusLabel = makeLabel(root, "READY", UDim2.new(0, 260, 0, 20), UDim2.new(1, -268, 0, toolbarHeight + 5), 10, 9, Enum.TextXAlignment.Right)
    statusLabel.TextColor3 = COLORS.secondary

    local mobileControls = makeFrame(root, "MobileControls", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), COLORS.background, 7)
    mobileControls.BackgroundTransparency = 1
    mobileControls.Visible = isTouchDevice
    mobileControls.Active = false
    local joystickBase = makeFrame(mobileControls, "JoystickBase", UDim2.fromOffset(86, 86), UDim2.new(0, 252, 1, -timelineHeight - 96), COLORS.panel2, 8)
    joystickBase.BackgroundTransparency = 0.12
    joystickBase.Active = true
    makeCorner(joystickBase, 43)
    makeStroke(joystickBase, COLORS.border, 1)
    local joystickKnob = makeFrame(joystickBase, "JoystickKnob", UDim2.fromOffset(34, 34), UDim2.new(0.5, 0, 0.5, 0), COLORS.active, 9)
    joystickKnob.AnchorPoint = Vector2.new(0.5, 0.5)
    makeCorner(joystickKnob, 17)
    local upBtn = makeButton(mobileControls, "UP", UDim2.fromOffset(44, 44), UDim2.new(1, -102, 1, -timelineHeight - 56), 9)
    local downBtn = makeButton(mobileControls, "DOWN", UDim2.fromOffset(44, 44), UDim2.new(1, -52, 1, -timelineHeight - 56), 9)

    -----------------------------------------------------------------
    -- SETTINGS MODAL
    -----------------------------------------------------------------
    local settingsBackdrop = makeFrame(root, "SettingsBackdrop", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), COLORS.background, 20)
    settingsBackdrop.BackgroundTransparency = 0.28
    settingsBackdrop.Visible = false
    settingsBackdrop.Active = true
    local settingsPanel = makeFrame(settingsBackdrop, "SettingsPanel", isTouchDevice and UDim2.new(0.94, 0, 0.88, 0) or UDim2.fromOffset(440, 560), isTouchDevice and UDim2.new(0.03, 0, 0.06, 0) or UDim2.new(0.5, -220, 0.5, -280), COLORS.panel, 21)
    settingsPanel.Active = true
    makeStroke(settingsPanel, COLORS.border, 1)
    makeCorner(settingsPanel, 5)
    makePadding(settingsPanel, 12, 10, 12, 10)
    local settingsTitle = makeLabel(settingsPanel, "PROJECT / CAMERA SETTINGS", UDim2.new(1, -36, 0, 28), UDim2.fromOffset(0, 0), 14, 22)
    settingsTitle.Font = Enum.Font.GothamBold
    local settingsClose = makeButton(settingsPanel, "X", UDim2.fromOffset(28, 25), UDim2.new(1, -28, 0, 1), 22)
    local settingsScroll = Instance.new("ScrollingFrame")
    settingsScroll.Position = UDim2.fromOffset(0, 34)
    settingsScroll.Size = UDim2.new(1, 0, 1, -34)
    settingsScroll.BackgroundTransparency = 1
    settingsScroll.BorderSizePixel = 0
    settingsScroll.ScrollBarThickness = 4
    settingsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    settingsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    settingsScroll.ZIndex = 22
    settingsScroll.Parent = settingsPanel
    local settingsLayout = Instance.new("UIListLayout")
    settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    settingsLayout.Padding = UDim.new(0, 5)
    settingsLayout.Parent = settingsScroll
    local function section(text, order)
        local l = makeLabel(settingsScroll, text, UDim2.new(1, 0, 0, 20), nil, 10, 22)
        l.Font = Enum.Font.GothamBold
        l.TextColor3 = COLORS.muted
        l.LayoutOrder = order
        return l
    end
    local function settingsField(text, default, order)
        local row = makeFrame(settingsScroll, "Setting_" .. text, UDim2.new(1, 0, 0, 25), nil, COLORS.panel, 22)
        row.LayoutOrder = order
        local label = makeLabel(row, text, UDim2.new(0.52, -4, 1, 0), UDim2.fromOffset(2, 0), 11, 23)
        label.TextColor3 = COLORS.secondary
        local box = makeTextBox(row, "", UDim2.new(0.48, -2, 1, 0), UDim2.new(0.52, 2, 0, 0), 23)
        box.Text = tostring(default)
        return box
    end
    local function settingsButton(text, order)
        local b = makeButton(settingsScroll, text, UDim2.new(1, 0, 0, isTouchDevice and 32 or 27), nil, 22)
        b.LayoutOrder = order
        return b
    end

    section("CAMERA", 1)
    local camSpeedBox = settingsField("Movement speed", camMoveSpeed, 2)
    local sensitivityBox = settingsField("Look sensitivity", camSensitivity, 3)
    local defaultFovBox = settingsField("Default FOV", defaultFOV, 4)
    local rollBox = settingsField("Camera roll (degrees)", 0, 5)
    local orbitDistanceBox = settingsField("Orbit distance", orbitDistance, 6)
    local orbitTargetXBox = settingsField("Orbit target X", orbitTarget.X, 7)
    local orbitTargetYBox = settingsField("Orbit target Y", orbitTarget.Y, 8)
    local orbitTargetZBox = settingsField("Orbit target Z", orbitTarget.Z, 9)
    local lookTargetXBox = settingsField("Look-at target X", lookAtTarget.X, 10)
    local lookTargetYBox = settingsField("Look-at target Y", lookAtTarget.Y, 11)
    local lookTargetZBox = settingsField("Look-at target Z", lookAtTarget.Z, 12)
    local orbitToggleBtn = settingsButton("ORBIT: OFF", 13)
    local lookAtToggleBtn = settingsButton("LOOK AT TARGET: OFF", 14)
    local applyCameraSettingsBtn = settingsButton("APPLY CAMERA SETTINGS", 15)

    section("COMPOSITION GUIDES / PATH", 16)
    local thirdsBtn = settingsButton("RULE OF THIRDS: OFF", 17)
    local centerBtn = settingsButton("CENTER CROSSHAIR: OFF", 18)
    local safe169Btn = settingsButton("16:9 SAFE FRAME: OFF", 19)
    local safe43Btn = settingsButton("4:3 SAFE FRAME: OFF", 20)
    local safe235Btn = settingsButton("2.35:1 CINEMATIC FRAME: OFF", 21)
    local pathToggleBtn = settingsButton("CAMERA PATH: OFF", 22)

    section("SHOT MANAGER", 23)
    local shotNameBox = settingsField("Shot name", "Shot 01", 24)
    local newShotBtn = settingsButton("CREATE NEW SHOT", 25)
    local duplicateShotBtn = settingsButton("DUPLICATE CURRENT SHOT", 26)
    local renameShotBtn = settingsButton("RENAME CURRENT SHOT", 27)
    local deleteShotBtn = settingsButton("DELETE CURRENT SHOT", 28)
    local previousShotBtn = settingsButton("PREVIOUS SHOT", 29)
    local nextShotBtn = settingsButton("NEXT SHOT", 30)
    local shotStatus = makeLabel(settingsScroll, "Shot 1 / 1", UDim2.new(1, 0, 0, 18), nil, 10, 22)
    shotStatus.LayoutOrder = 31
    shotStatus.TextColor3 = COLORS.muted

    section("CAMERA BOOKMARKS", 32)
    local bookmarkNameBox = settingsField("Bookmark name", "Bookmark", 33)
    local saveBookmarkBtn = settingsButton("SAVE CURRENT CAMERA", 34)
    local applyBookmarkBtn = settingsButton("APPLY SELECTED BOOKMARK", 35)
    local renameBookmarkBtn = settingsButton("RENAME SELECTED BOOKMARK", 36)
    local deleteBookmarkBtn = settingsButton("DELETE SELECTED BOOKMARK", 37)
    local nextBookmarkBtn = settingsButton("NEXT BOOKMARK", 38)
    local bookmarkStatus = makeLabel(settingsScroll, "No bookmarks", UDim2.new(1, 0, 0, 18), nil, 10, 22)
    bookmarkStatus.LayoutOrder = 39
    bookmarkStatus.TextColor3 = COLORS.muted

    section("PLAYBACK / PROJECT DATA", 40)
    local countdownBox = settingsField("Countdown seconds", countdownSeconds, 41)
    local exportBtn = settingsButton("EXPORT COMPLETE PROJECT JSON", 42)
    local jsonBox = Instance.new("TextBox")
    jsonBox.Name = "ProjectJSON"
    jsonBox.Size = UDim2.new(1, 0, 0, isTouchDevice and 110 or 140)
    jsonBox.BackgroundColor3 = COLORS.input
    jsonBox.TextColor3 = COLORS.text
    jsonBox.PlaceholderColor3 = COLORS.muted
    jsonBox.PlaceholderText = "Exported project JSON appears here. Paste a project JSON document to import."
    jsonBox.Font = Enum.Font.Code
    jsonBox.TextSize = isTouchDevice and 9 or 11
    jsonBox.Text = ""
    jsonBox.ClearTextOnFocus = false
    jsonBox.MultiLine = true
    jsonBox.TextWrapped = false
    jsonBox.TextXAlignment = Enum.TextXAlignment.Left
    jsonBox.TextYAlignment = Enum.TextYAlignment.Top
    jsonBox.BorderSizePixel = 0
    jsonBox.LayoutOrder = 43
    jsonBox.ZIndex = 22
    jsonBox.Parent = settingsScroll
    makeCorner(jsonBox, 3)
    makeStroke(jsonBox, COLORS.border, 1)
    local importBtn = settingsButton("IMPORT PROJECT JSON", 44)
    local settingsStatus = makeLabel(settingsScroll, "", UDim2.new(1, 0, 0, 22), nil, 10, 22)
    settingsStatus.LayoutOrder = 45
    settingsStatus.TextColor3 = COLORS.secondary

    -----------------------------------------------------------------
    -- HELP / COUNTDOWN
    -----------------------------------------------------------------
    local helpBackdrop = makeFrame(root, "HelpBackdrop", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), COLORS.background, 30)
    helpBackdrop.BackgroundTransparency = 0.25
    helpBackdrop.Visible = false
    helpBackdrop.Active = true
    local helpPanel = makeFrame(helpBackdrop, "HelpPanel", isTouchDevice and UDim2.new(0.9, 0, 0.66, 0) or UDim2.fromOffset(390, 330), isTouchDevice and UDim2.new(0.05, 0, 0.17, 0) or UDim2.new(0.5, -195, 0.5, -165), COLORS.panel, 31)
    helpPanel.Active = true
    makeStroke(helpPanel, COLORS.border, 1)
    makeCorner(helpPanel, 5)
    makePadding(helpPanel, 14, 12, 14, 12)
    local helpTitle = makeLabel(helpPanel, "CONTROLS", UDim2.new(1, -32, 0, 24), nil, 14, 32)
    helpTitle.Font = Enum.Font.GothamBold
    local helpClose = makeButton(helpPanel, "X", UDim2.fromOffset(26, 23), UDim2.new(1, -26, 0, 0), 32)
    local helpText = makeLabel(helpPanel, "", UDim2.new(1, 0, 1, -34), UDim2.fromOffset(0, 34), 12, 32)
    helpText.TextYAlignment = Enum.TextYAlignment.Top
    helpText.TextWrapped = true
    helpText.TextColor3 = COLORS.secondary
    helpText.Text = isTouchDevice
        and "JOYSTICK: move\nDrag the empty viewport: look around\nUP / DOWN: pedestal movement\nTimeline: drag to scrub; drag markers to move\nSelect multiple markers with Shift on supported keyboards\nUse SETTINGS for orbit, look-at, guides, shots and bookmarks\nTwo-finger touch during playback: stop and restore interfaces\n/replay: hide or show FramePlay"
        or "W A S D: move | E / Q: pedestal\nRight mouse drag: look around\nShift: speed boost | Mouse wheel: speed or orbit distance\nSpace: play / pause | Esc: stop playback\nDelete: remove | Ctrl+D: duplicate\nCtrl+C / Ctrl+V: copy / paste keyframes\nCtrl+Z / Ctrl+Y: undo / redo\nLeft / Right arrows: one-frame navigation\nShift-click markers: multi-select\n/replay: hide or show FramePlay"

    local countdownOverlay = makeFrame(root, "Countdown", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), COLORS.background, 40)
    countdownOverlay.BackgroundTransparency = 0.3
    countdownOverlay.Visible = false
    countdownOverlay.Active = true
    local countdownLabel = makeLabel(countdownOverlay, "3", UDim2.fromOffset(180, 150), UDim2.new(0.5, -90, 0.5, -75), 84, 41, Enum.TextXAlignment.Center)
    countdownLabel.Font = Enum.Font.GothamBold
    local countdownHint = makeLabel(countdownOverlay, "STOP / ESC TO CANCEL", UDim2.new(1, 0, 0, 24), UDim2.new(0, 0, 0.5, 82), 11, 41, Enum.TextXAlignment.Center)
    countdownHint.TextColor3 = COLORS.muted

    -----------------------------------------------------------------
    -- COMPOSITION GUIDE OVERLAYS (NON-INTERACTIVE)
    -----------------------------------------------------------------
    local guideLayer = makeFrame(root, "CompositionGuides", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), COLORS.background, 3)
    guideLayer.BackgroundTransparency = 1
    guideLayer.Active = false
    local guideObjects = {}
    local function guideLine(name, size, pos)
        local line = makeFrame(guideLayer, name, size, pos, COLORS.white, 3)
        line.BackgroundTransparency = 0.48
        line.Active = false
        guideObjects[#guideObjects + 1] = line
        return line
    end
    local thirdsLines = {
        guideLine("ThirdV1", UDim2.new(0, 1, 0.78, 0), UDim2.new(1/3, 0, 0.11, 0)),
        guideLine("ThirdV2", UDim2.new(0, 1, 0.78, 0), UDim2.new(2/3, 0, 0.11, 0)),
        guideLine("ThirdH1", UDim2.new(0.94, 0, 0, 1), UDim2.new(0.03, 0, 0.11 + 0.78/3, 0)),
        guideLine("ThirdH2", UDim2.new(0.94, 0, 0, 1), UDim2.new(0.03, 0, 0.11 + 0.78*2/3, 0)),
    }
    local centerLines = {
        guideLine("CenterV", UDim2.new(0, 1, 0.78, 0), UDim2.new(0.5, 0, 0.11, 0)),
        guideLine("CenterH", UDim2.new(0.94, 0, 0, 1), UDim2.new(0.03, 0, 0.5, 0)),
    }
    local function makeSafeFrame(name, aspect)
        local frame = Instance.new("Frame")
        frame.Name = name
        frame.BackgroundTransparency = 1
        frame.BorderSizePixel = 0
        frame.AnchorPoint = Vector2.new(0.5, 0.5)
        frame.Position = UDim2.new(0.5, 0, 0.5, 0)
        frame.Size = UDim2.new(1, 0, 1, 0)
        frame.ZIndex = 3
        frame.Parent = guideLayer
        makeStroke(frame, COLORS.white, 1, 0.4)
        guideObjects[#guideObjects + 1] = frame
        frame:SetAttribute("Aspect", aspect)
        return frame
    end
    local safe169 = makeSafeFrame("Safe169", 16/9)
    local safe43 = makeSafeFrame("Safe43", 4/3)
    local safe235 = makeSafeFrame("Safe235", 2.35)

    -----------------------------------------------------------------
    -- UI REFRESH FUNCTIONS
    -----------------------------------------------------------------
    setStatus = function(message)
        if statusLabel and statusLabel.Parent then
            statusLabel.Text = safeText(message, 80)
            statusLabel.TextColor3 = COLORS.secondary
        end
    end
    local function formatTime(value)
        local minutes = math.floor(value / 60)
        local seconds = value - minutes * 60
        return string.format("%02d:%05.2f", minutes, seconds)
    end
    local function timelinePixelsPerSecond()
        return 80 * timelineZoom
    end
    local function timelineContentWidth()
        local visible = math.max(1, trackScroll.AbsoluteWindowSize.X)
        return math.max(visible, duration * timelinePixelsPerSecond() + 24)
    end
    local function updateTimelineCanvas()
        local width = timelineContentWidth()
        trackCanvas.Size = UDim2.new(0, width, 1, 0)
        trackScroll.CanvasSize = UDim2.new(0, width, 0, 0)
    end
    local function timeToX(t) return t * timelinePixelsPerSecond() end
    local function screenToTimelineTime(screenX)
        local localX = screenX - trackScroll.AbsolutePosition.X + trackScroll.CanvasPosition.X
        return clamp(localX / timelinePixelsPerSecond(), 0, duration)
    end
    updatePlayheadVisual = function()
        if not playhead then return end
        playhead.Position = UDim2.new(0, timeToX(currentTime), 0, 0)
    end
    updateTimeDisplays = function()
        if timeLabel then timeLabel.Text = formatTime(currentTime) .. " / " .. formatTime(duration) end
        if durationBox and not UserInputService:GetFocusedTextBox() then durationBox.Text = tostring(round(duration, 2)) end
        if speedBox and not UserInputService:GetFocusedTextBox() then speedBox.Text = tostring(round(playbackSpeed, 2)) end
    end
    refreshRuler = function()
        for _, child in ipairs(ruler:GetChildren()) do if child ~= nil then child:Destroy() end end
        updateTimelineCanvas()
        local pps = timelinePixelsPerSecond()
        local step = math.max(1, math.ceil(duration / 30))
        for t = 0, duration, step do
            local x = t * pps
            local tick = makeFrame(ruler, "Tick", UDim2.new(0, 1, 0, 7), UDim2.fromOffset(x, 10), COLORS.border, 6)
            local label = makeLabel(ruler, tostring(t) .. "s", UDim2.fromOffset(36, 13), UDim2.fromOffset(x + 3, 1), 9, 6)
            label.TextColor3 = COLORS.muted
        end
    end
    refreshKeyframeList = function()
        disconnectBucket(listConnections)
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("GuiObject") and not child:IsA("UIListLayout") then child:Destroy() end
        end
        for index, k in ipairs(keyframes) do
            local row = makeButton(listFrame, string.format("%02d   %.3fs", index, k.time), UDim2.new(1, 0, 0, isTouchDevice and 29 or 24), nil, 6)
            row.LayoutOrder = index
            row.TextXAlignment = Enum.TextXAlignment.Left
            if selectedIds[k.id] or selectedKeyframe == k then row.BackgroundColor3 = COLORS.selected end
            makePadding(row, 7, 0, 4, 0)
            connect(row.Activated, function() selectKeyframe(k); seekTo(k.time) end, listConnections)
        end
        if #keyframes == 0 then
            local empty = makeLabel(listFrame, "No keyframes yet", UDim2.new(1, 0, 0, 24), nil, 10, 6, Enum.TextXAlignment.Center)
            empty.TextColor3 = COLORS.muted
        end
    end
    refreshSelectedPanel = function()
        local k = selectedKeyframe
        if not k then
            for _, box in ipairs({posXBox, posYBox, posZBox, rotXBox, rotYBox, rotZBox, fovBox, timeBox}) do
                if not UserInputService:GetFocusedTextBox() then box.Text = "" end
            end
            segmentEaseBtn.Text = "EASING: -"
            interpolationBtn.Text = "PATH: -"
            return
        end
        local p = k.cframe.Position
        local rx, ry, rz = k.cframe:ToOrientation()
        local values = {
            {posXBox, p.X}, {posYBox, p.Y}, {posZBox, p.Z},
            {rotXBox, math.deg(rx)}, {rotYBox, math.deg(ry)}, {rotZBox, math.deg(rz)},
            {fovBox, k.fov}, {timeBox, k.time},
        }
        for _, pair in ipairs(values) do
            if UserInputService:GetFocusedTextBox() ~= pair[1] then pair[1].Text = tostring(round(pair[2], 3)) end
        end
        segmentEaseBtn.Text = "EASING: " .. (k.easing or easingDefault)
        interpolationBtn.Text = "PATH: " .. (k.interpolation or "Linear")
    end
    refreshTimelineMarkers = function()
        disconnectBucket(markerConnections)
        for _, child in ipairs(markerLane:GetChildren()) do
            if child ~= playhead then child:Destroy() end
        end
        updateTimelineCanvas()
        for _, k in ipairs(keyframes) do
            local marker = makeButton(markerLane, "", UDim2.fromOffset(12, 16), UDim2.fromOffset(timeToX(k.time) - 6, 24), 7)
            marker.Name = "Keyframe_" .. tostring(k.id)
            marker.Text = ""
            marker.BackgroundColor3 = (selectedIds[k.id] or selectedKeyframe == k) and COLORS.white or COLORS.muted
            marker.AutoButtonColor = false
            marker.AnchorPoint = Vector2.new(0, 0.5)
            makeCorner(marker, 2)
            makeStroke(marker, COLORS.background, 1)
            connect(marker.InputBegan, function(input)
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
                local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
                if shift then
                    selectKeyframe(k, true)
                    if not selectedIds[k.id] then return end
                else
                    selectKeyframe(k)
                end
                local startTime = k.time
                local movingSet = {}
                local initialTimes = {}
                for id in pairs(selectedIds) do movingSet[id] = true end
                if selectedKeyframe then movingSet[selectedKeyframe.id] = true end
                local movingItems = {}
                for _, item in ipairs(keyframes) do
                    if movingSet[item.id] then
                        movingItems[#movingItems + 1] = item
                        initialTimes[item.id] = item.time
                    end
                end
                local historyPushed = false
                local active = true
                local moveConn, endConn
                moveConn = connect(UserInputService.InputChanged, function(moveInput)
                    if not active then return end
                    if moveInput.UserInputType == Enum.UserInputType.MouseMovement or (moveInput.UserInputType == Enum.UserInputType.Touch and moveInput == input) then
                        local target = screenToTimelineTime(moveInput.Position.X)
                        local rawDelta = target - startTime
                        if snapEnabled then rawDelta = round(rawDelta / timelineSnapFrame) * timelineSnapFrame end
                        local minT, maxT = math.huge, -math.huge
                        for _, item in ipairs(movingItems) do
                            local initial = initialTimes[item.id]
                            minT = math.min(minT, initial)
                            maxT = math.max(maxT, initial)
                        end
                        rawDelta = clamp(rawDelta, -minT, duration - maxT)
                        local canMove = true
                        for _, item in ipairs(movingItems) do
                            if findKeyframeNear(initialTimes[item.id] + rawDelta, movingSet) then
                                canMove = false
                                break
                            end
                        end
                        if canMove then
                            if math.abs(rawDelta) > 0.0001 and not historyPushed then
                                pushUndo()
                                historyPushed = true
                            end
                            for _, item in ipairs(movingItems) do
                                item.time = clamp(initialTimes[item.id] + rawDelta, 0, duration)
                            end
                            sortKeyframes()
                            currentTime = clamp(k.time, 0, duration)
                            refreshKeyframeList(); refreshTimelineMarkers(); updatePlayheadVisual(); refreshPathVisualization()
                            updateTimeDisplays()
                        else
                            setStatus("Move blocked: another keyframe occupies that time.")
                        end
                    end
                end, temporaryConnections)
                endConn = connect(UserInputService.InputEnded, function(endInput)
                    if endInput == input or (input.UserInputType == Enum.UserInputType.MouseButton1 and endInput.UserInputType == Enum.UserInputType.MouseButton1) then
                        active = false
                        disconnectTracked(moveConn, temporaryConnections)
                        disconnectTracked(endConn, temporaryConnections)
                        refreshTimelineMarkers(); refreshSelectedPanel(); refreshPathVisualization()
                    end
                end, temporaryConnections)
            end, markerConnections)
        end
        updatePlayheadVisual()
    end

    updateGuideVisibility = function()
        for _, object in ipairs(guideObjects) do object.Visible = false end
        for _, object in ipairs(thirdsLines) do object.Visible = guideSettings.thirds end
        for _, object in ipairs(centerLines) do object.Visible = guideSettings.center end
        local rootSize = root.AbsoluteSize
        local function fit(frame, aspect)
            if rootSize.X <= 0 or rootSize.Y <= 0 then return end
            local w, h = rootSize.X, rootSize.Y
            if w / h > aspect then w = h * aspect else h = w / aspect end
            frame.Size = UDim2.fromOffset(w, h)
        end
        fit(safe169, 16/9); fit(safe43, 4/3); fit(safe235, 2.35)
        safe169.Visible = guideSettings.safe169
        safe43.Visible = guideSettings.safe43
        safe235.Visible = guideSettings.safe235
        thirdsBtn.Text = "RULE OF THIRDS: " .. (guideSettings.thirds and "ON" or "OFF")
        centerBtn.Text = "CENTER CROSSHAIR: " .. (guideSettings.center and "ON" or "OFF")
        safe169Btn.Text = "16:9 SAFE FRAME: " .. (guideSettings.safe169 and "ON" or "OFF")
        safe43Btn.Text = "4:3 SAFE FRAME: " .. (guideSettings.safe43 and "ON" or "OFF")
        safe235Btn.Text = "2.35:1 CINEMATIC FRAME: " .. (guideSettings.safe235 and "ON" or "OFF")
    end
    updateShotControls = function()
        local shot = shots[currentShotIndex]
        shotNameBox.Text = shot and shot.name or ""
        shotStatus.Text = string.format("%s  |  Shot %d / %d", shot and shot.name or "No shot", currentShotIndex, #shots)
        if shot then
            camSpeedBox.Text = tostring(camMoveSpeed)
            sensitivityBox.Text = tostring(camSensitivity)
            defaultFovBox.Text = tostring(defaultFOV)
            orbitDistanceBox.Text = tostring(orbitDistance)
            orbitTargetXBox.Text = tostring(orbitTarget.X)
            orbitTargetYBox.Text = tostring(orbitTarget.Y)
            orbitTargetZBox.Text = tostring(orbitTarget.Z)
            lookTargetXBox.Text = tostring(lookAtTarget.X)
            lookTargetYBox.Text = tostring(lookAtTarget.Y)
            lookTargetZBox.Text = tostring(lookAtTarget.Z)
            orbitToggleBtn.Text = "ORBIT: " .. (orbitEnabled and "ON" or "OFF")
            lookAtToggleBtn.Text = "LOOK AT TARGET: " .. (lookAtEnabled and "ON" or "OFF")
            modeBtn.Text = "MODE: " .. string.upper(cameraMode)
            loopBtn.Text = loopPlayback and "LOOP ON" or "LOOP OFF"
            regionBtn.Text = loopRegionEnabled and "REGION ON" or "REGION OFF"
            reverseBtn.Text = reversePlayback and "REVERSE ON" or "REVERSE OFF"
        end
    end
    updateBookmarkControls = function()
        if #bookmarks == 0 then
            selectedBookmark = 0
            bookmarkStatus.Text = "No bookmarks"
        else
            selectedBookmark = clamp(selectedBookmark, 1, #bookmarks)
            bookmarkStatus.Text = string.format("%d / %d  -  %s", selectedBookmark, #bookmarks, bookmarks[selectedBookmark].name)
            bookmarkNameBox.Text = bookmarks[selectedBookmark].name
        end
    end
    refreshPathVisualization = function()
        if not pathFolder then return end
        for _, child in ipairs(pathFolder:GetChildren()) do child:Destroy() end
        if not showPath or #keyframes == 0 then return end
        local function makeMarker(position, selected)
            local part = Instance.new("Part")
            part.Name = selected and "SelectedKeyframePoint" or "KeyframePoint"
            part.Shape = Enum.PartType.Ball
            part.Size = selected and Vector3.new(0.8, 0.8, 0.8) or Vector3.new(0.45, 0.45, 0.45)
            part.Material = Enum.Material.SmoothPlastic
            part.Color = selected and COLORS.white or COLORS.muted
            part.Transparency = 0.12
            part.Anchored = true
            part.CanCollide = false
            part.CanTouch = false
            part.CanQuery = false
            part.CFrame = CFrame.new(position)
            part.Parent = pathFolder
        end
        local function makeSegment(a, b)
            local delta = b - a
            if delta.Magnitude < 0.01 then return end
            local part = Instance.new("Part")
            part.Name = "CameraPathSegment"
            part.Size = Vector3.new(0.07, 0.07, delta.Magnitude)
            part.Material = Enum.Material.SmoothPlastic
            part.Color = COLORS.secondary
            part.Transparency = 0.35
            part.Anchored = true
            part.CanCollide = false
            part.CanTouch = false
            part.CanQuery = false
            part.CFrame = CFrame.lookAt((a + b) / 2, b)
            part.Parent = pathFolder
        end
        local markerStep = math.max(1, math.ceil(#keyframes / 150))
        for index, k in ipairs(keyframes) do
            local include = index == 1 or index == #keyframes or index % markerStep == 0 or k == selectedKeyframe
            if include then
                makeMarker(k.cframe.Position, k == selectedKeyframe)
                local direction = Instance.new("Part")
                direction.Name = "CameraDirection"
                direction.Size = Vector3.new(0.12, 0.12, 1.1)
                direction.Material = Enum.Material.SmoothPlastic
                direction.Color = COLORS.white
                direction.Transparency = 0.25
                direction.Anchored = true
                direction.CanCollide = false
                direction.CanTouch = false
                direction.CanQuery = false
                direction.CFrame = k.cframe * CFrame.new(0, 0, -0.65)
                direction.Parent = pathFolder
            end
        end
        local segmentStep = math.max(1, math.ceil((#keyframes - 1) / 60))
        for index = 1, #keyframes - 1, segmentStep do
            local a = keyframes[index]
            local b = keyframes[math.min(#keyframes, index + segmentStep)]
            local previousPosition = a.cframe.Position
            for sample = 1, 6 do
                local sampleTime = a.time + (b.time - a.time) * (sample / 6)
                local sampleCFrame = getCameraStateAtTime(sampleTime)
                if sampleCFrame then
                    makeSegment(previousPosition, sampleCFrame.Position)
                    previousPosition = sampleCFrame.Position
                end
            end
        end
    end

    updateUIReferences = function()
        updateShotControls()
        updateBookmarkControls()
        refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshRuler()
        updatePlayheadVisual(); updateTimeDisplays(); refreshPathVisualization()
        UI.loopBtn.Text = loopPlayback and "LOOP ON" or "LOOP OFF"
        UI.regionBtn.Text = loopRegionEnabled and "REGION ON" or "REGION OFF"
        UI.reverseBtn.Text = reversePlayback and "REVERSE ON" or "REVERSE OFF"
        UI.snapBtn.Text = snapEnabled and ("SNAP " .. snapFPS) or "SNAP OFF"
        UI.modeBtn.Text = "MODE: " .. string.upper(cameraMode)
    end

    return {
        gui = screenGui, root = root, toolbarHeight = toolbarHeight, toolbar = toolbar,
        leftPanel = leftPanel, timeline = timeline, listFrame = listFrame, inspectorScroll = inspectorScroll,
        playBtn = playBtn, pauseBtn = pauseBtn, stopBtn = stopBtn, addBtn = addBtn, deleteBtn = deleteBtn,
        undoBtn = undoBtn, redoBtn = redoBtn, copyBtn = copyBtn, pasteBtn = pasteBtn, modeBtn = modeBtn,
        panelBtn = panelBtn, settingsBtn = settingsBtn, helpBtn = helpBtn, closeBtn = closeBtn,
        posXBox = posXBox, posYBox = posYBox, posZBox = posZBox, rotXBox = rotXBox, rotYBox = rotYBox,
        rotZBox = rotZBox, fovBox = fovBox, timeBox = timeBox, segmentEaseBtn = segmentEaseBtn,
        interpolationBtn = interpolationBtn, applyFieldsBtn = applyFieldsBtn, snapCameraBtn = snapCameraBtn,
        duplicateBtn = duplicateBtn, deleteSelectedBtn = deleteSelectedBtn, clearAllBtn = clearAllBtn,
        prevFrameBtn = prevFrameBtn, nextFrameBtn = nextFrameBtn, restartTimelineBtn = restartTimelineBtn, prevKeyBtn = prevKeyBtn, nextKeyBtn = nextKeyBtn,
        zoomOutBtn = zoomOutBtn, zoomInBtn = zoomInBtn, durationBox = durationBox, speedBox = speedBox,
        loopBtn = loopBtn, loopInBtn = loopInBtn, loopOutBtn = loopOutBtn, regionBtn = regionBtn, reverseBtn = reverseBtn, snapBtn = snapBtn, trackScroll = trackScroll,
        trackCanvas = trackCanvas, markerLane = markerLane, playhead = playhead, toolbarScroll = toolbarScroll,
        mobileControls = mobileControls, joystickBase = joystickBase, joystickKnob = joystickKnob,
        upBtn = upBtn, downBtn = downBtn, settingsBackdrop = settingsBackdrop, settingsClose = settingsClose,
        camSpeedBox = camSpeedBox, sensitivityBox = sensitivityBox, defaultFovBox = defaultFovBox,
        rollBox = rollBox, orbitDistanceBox = orbitDistanceBox, orbitTargetXBox = orbitTargetXBox,
        orbitTargetYBox = orbitTargetYBox, orbitTargetZBox = orbitTargetZBox, lookTargetXBox = lookTargetXBox,
        lookTargetYBox = lookTargetYBox, lookTargetZBox = lookTargetZBox, orbitToggleBtn = orbitToggleBtn,
        lookAtToggleBtn = lookAtToggleBtn, applyCameraSettingsBtn = applyCameraSettingsBtn,
        thirdsBtn = thirdsBtn, centerBtn = centerBtn, safe169Btn = safe169Btn, safe43Btn = safe43Btn,
        safe235Btn = safe235Btn, pathToggleBtn = pathToggleBtn, shotNameBox = shotNameBox,
        newShotBtn = newShotBtn, duplicateShotBtn = duplicateShotBtn, renameShotBtn = renameShotBtn,
        deleteShotBtn = deleteShotBtn, previousShotBtn = previousShotBtn, nextShotBtn = nextShotBtn,
        shotStatus = shotStatus, bookmarkNameBox = bookmarkNameBox, saveBookmarkBtn = saveBookmarkBtn,
        applyBookmarkBtn = applyBookmarkBtn, renameBookmarkBtn = renameBookmarkBtn,
        deleteBookmarkBtn = deleteBookmarkBtn, nextBookmarkBtn = nextBookmarkBtn,
        bookmarkStatus = bookmarkStatus, countdownBox = countdownBox, exportBtn = exportBtn,
        jsonBox = jsonBox, importBtn = importBtn, settingsStatus = settingsStatus,
        helpBackdrop = helpBackdrop, helpClose = helpClose, countdownOverlay = countdownOverlay,
        countdownLabel = countdownLabel, touchCatcher = touchCatcher, statusLabel = statusLabel,
        safe169 = safe169, safe43 = safe43, safe235 = safe235,
    }
end

local buildOk, buildResult = pcall(buildUI)
if not buildOk then
    warn("[FramePlay] UI construction failed: " .. tostring(buildResult))
    disconnectBucket(connections)
    return
end
UI = buildResult

---------------------------------------------------------------------
-- RESPONSIVE LAYOUT / CAMERA PATH CONTAINER
---------------------------------------------------------------------
local inspectorVisible = true
local panelWidth = isTouchDevice and 170 or 250
local timelineHeight = isTouchDevice and 112 or 154
local function relayout()
    if not UI.root or not UI.root.Parent then return end
    local size = UI.root.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then return end
    if isTouchDevice then
        panelWidth = clamp(math.floor(size.X * (size.Y > size.X and 0.42 or 0.30)), 140, 220)
        timelineHeight = clamp(math.floor(size.Y * 0.18), 96, 136)
    else
        panelWidth = clamp(math.floor(size.X * 0.19), 220, 310)
        timelineHeight = clamp(math.floor(size.Y * 0.20), 140, 180)
    end
    UI.leftPanel.Position = UDim2.new(0, 0, 0, UI.toolbarHeight)
    UI.leftPanel.Size = UDim2.new(0, inspectorVisible and panelWidth or 0, 1, -UI.toolbarHeight - timelineHeight)
    UI.leftPanel.Visible = inspectorVisible
    UI.timeline.Size = UDim2.new(1, 0, 0, timelineHeight)
    UI.timeline.Position = UDim2.new(0, 0, 1, -timelineHeight)
    UI.joystickBase.Position = UDim2.new(0, (inspectorVisible and panelWidth or 8) + 12, 1, -timelineHeight - 98)
    UI.upBtn.Position = UDim2.new(1, -102, 1, -timelineHeight - 56)
    UI.downBtn.Position = UDim2.new(1, -52, 1, -timelineHeight - 56)
    UI.statusLabel.Position = UDim2.new(1, -268, 0, UI.toolbarHeight + 5)
    refreshRuler(); refreshTimelineMarkers(); updatePlayheadVisual(); updateGuideVisibility()
end
connect(UI.root:GetPropertyChangedSignal("AbsoluteSize"), relayout)

pathFolder = Instance.new("Folder")
pathFolder.Name = "FramePlay_LocalPathPreview"
pathFolder.Parent = Workspace

---------------------------------------------------------------------
-- CAMERA TRANSFORMS / ORBIT / LOOK-AT
---------------------------------------------------------------------
local function extractRoll(cf)
    local _, _, rz = cf:ToOrientation()
    return rz
end
local function applyLookAt(cf)
    if not lookAtEnabled then return cf end
    local direction = lookAtTarget - cf.Position
    if direction.Magnitude < 0.001 then return cf end
    return CFrame.lookAt(cf.Position, lookAtTarget) * CFrame.Angles(0, 0, extractRoll(cf))
end
local function orbitCFrame()
    local cp = math.cos(orbitPitch)
    local offset = Vector3.new(math.sin(orbitYaw) * cp, math.sin(orbitPitch), math.cos(orbitYaw) * cp) * orbitDistance
    local position = orbitTarget + offset
    return CFrame.lookAt(position, orbitTarget) * CFrame.Angles(0, 0, extractRoll(freeCamCFrame))
end
local function syncOrbitFromCamera()
    local offset = freeCamCFrame.Position - orbitTarget
    if offset.Magnitude < 0.001 then offset = Vector3.new(0, 0, 1) end
    orbitDistance = math.max(1, offset.Magnitude)
    orbitYaw = math.atan2(offset.X, offset.Z)
    orbitPitch = math.asin(clamp(offset.Unit.Y, -1, 1))
end
local function updateFreeCameraLook(delta)
    local rx, ry = freeCamCFrame:ToOrientation()
    if orbitEnabled or cameraMode == "Orbit" then
        orbitYaw -= math.rad(delta.X * camSensitivity)
        orbitPitch = clamp(orbitPitch - math.rad(delta.Y * camSensitivity), math.rad(-85), math.rad(85))
        freeCamCFrame = orbitCFrame()
        return
    end
    local yaw = ry
    local pitch = rx
    if cameraMode ~= "Tilt" then yaw -= math.rad(delta.X * camSensitivity) end
    if cameraMode ~= "Pan" then pitch = clamp(pitch - math.rad(delta.Y * camSensitivity), math.rad(-89), math.rad(89)) end
    freeCamCFrame = CFrame.new(freeCamCFrame.Position) * CFrame.fromOrientation(pitch, yaw, extractRoll(freeCamCFrame))
end

---------------------------------------------------------------------
-- SEEK / PLAYBACK
---------------------------------------------------------------------
seekTo = function(t)
    currentTime = clamp(t, 0, duration)
    local cf, fov = getCameraStateAtTime(currentTime)
    if cf then
        cf = applyLookAt(cf)
        freeCamCFrame = cf
        currentFOV = clamp(fov or currentFOV, 1, 169)
        if camera then camera.CFrame = cf; camera.FieldOfView = currentFOV end
    end
    updatePlayheadVisual(); updateTimeDisplays()
end
local function cancelCountdown()
    countdownToken += 1
    countdownActive = false
    if UI.countdownOverlay then UI.countdownOverlay.Visible = false end
end
local function beginPlayback()
    if #keyframes == 0 then setStatus("Add at least one keyframe before playback."); return end
    local startPoint = loopRegionEnabled and loopRegionStart or 0
    local endPoint = loopRegionEnabled and loopRegionEnd or duration
    if endPoint <= startPoint then startPoint = 0; endPoint = duration end
    if reversePlayback and (currentTime <= startPoint or currentTime > endPoint) then currentTime = endPoint
    elseif not reversePlayback and (currentTime >= endPoint or currentTime < startPoint) then currentTime = startPoint end
    hidePlaybackGuis()
    isPlaying = true
    isPaused = false
end
local function playWithCountdown()
    if countdownActive or #keyframes == 0 then return end
    local enteredCountdown = tonumber(UI.countdownBox.Text)
    if finiteNumber(enteredCountdown) then countdownSeconds = clamp(math.floor(enteredCountdown), 0, 15) end
    UI.countdownBox.Text = tostring(countdownSeconds)
    if countdownSeconds <= 0 then beginPlayback(); return end
    countdownToken += 1
    local token = countdownToken
    countdownActive = true
    UI.countdownOverlay.Visible = true
    task.spawn(function()
        for n = countdownSeconds, 1, -1 do
            if cleanedUp or token ~= countdownToken then return end
            UI.countdownLabel.Text = tostring(n)
            task.wait(1)
        end
        if cleanedUp or token ~= countdownToken then return end
        UI.countdownOverlay.Visible = false
        countdownActive = false
        beginPlayback()
    end)
end
local function finishPlayback()
    isPlaying = false
    isPaused = false
    restorePlaybackGuis()
end
local function stopPlayback()
    cancelCountdown()
    finishPlayback()
    seekTo(reversePlayback and (loopRegionEnabled and loopRegionEnd or duration) or (loopRegionEnabled and loopRegionStart or 0))
end
local function restartPlayback()
    if #keyframes == 0 then return end
    cancelCountdown()
    currentTime = reversePlayback and (loopRegionEnabled and loopRegionEnd or duration) or (loopRegionEnabled and loopRegionStart or 0)
    beginPlayback()
end
local function togglePlayback()
    if countdownActive then return end
    if isPlaying then isPaused = not isPaused
    else playWithCountdown() end
end

---------------------------------------------------------------------
-- SHOT MANAGER
---------------------------------------------------------------------
local function switchShot(index)
    if index < 1 or index > #shots or index == currentShotIndex then return end
    if isPlaying then stopPlayback() end
    pushUndo()
    saveActiveShot()
    loadShot(index)
    if camera then camera.CFrame = freeCamCFrame; camera.FieldOfView = currentFOV end
    updateShotControls(); updateBookmarkControls()
    if refreshKeyframeList then refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshRuler(); seekTo(0); refreshPathVisualization() end
    setStatus("Switched to " .. shots[currentShotIndex].name)
end
local function createShot(duplicate)
    pushUndo()
    local source = shots[currentShotIndex]
    local shot
    if duplicate then
        shot = cloneShot(source)
        shot.name = source.name .. " Copy"
        shot.keyframes = copyKeyframes(source.keyframes)
    else
        shot = newShot("Shot " .. string.format("%02d", #shots + 1))
    end
    table.insert(shots, shot)
    loadShot(#shots)
    updateShotControls(); refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshRuler(); seekTo(0); refreshPathVisualization()
end
local function deleteShot()
    if #shots <= 1 then setStatus("The project must contain at least one shot."); return end
    pushUndo()
    table.remove(shots, currentShotIndex)
    currentShotIndex = clamp(currentShotIndex, 1, #shots)
    loadShot(currentShotIndex)
    updateShotControls(); refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshRuler(); seekTo(0); refreshPathVisualization()
end

---------------------------------------------------------------------
-- COPY / PASTE
---------------------------------------------------------------------
local function copySelected()
    copiedKeyframes = {}
    local ids = {}
    for id in pairs(selectedIds) do ids[id] = true end
    if selectedKeyframe then ids[selectedKeyframe.id] = true end
    local earliest = math.huge
    for _, k in ipairs(keyframes) do if ids[k.id] then earliest = math.min(earliest, k.time) end end
    if earliest == math.huge then return end
    for _, k in ipairs(keyframes) do
        if ids[k.id] then
            local copy = copyKeyframe(k)
            copy.offset = k.time - earliest
            copiedKeyframes[#copiedKeyframes + 1] = copy
        end
    end
    setStatus("Copied " .. #copiedKeyframes .. " keyframe(s).")
end
local function pasteCopied()
    if #copiedKeyframes == 0 then return end
    if #keyframes + #copiedKeyframes > MAX_KEYFRAMES_PER_SHOT then
        setStatus("Paste cancelled: this shot would exceed 1,000 keyframes.")
        return
    end
    local base = currentTime
    local candidates = {}
    for _, k in ipairs(copiedKeyframes) do
        local t = base + (k.offset or 0)
        if t > duration then setStatus("Paste cancelled: keyframes exceed shot duration."); return end
        if findKeyframeNear(t) then setStatus("Paste cancelled: destination time is occupied."); return end
        candidates[#candidates + 1] = { source = k, time = t }
    end
    pushUndo()
    selectedIds = {}
    selectedKeyframe = nil
    for _, item in ipairs(candidates) do
        keyframeIdCounter += 1
        local k = copyKeyframe(item.source)
        k.id = keyframeIdCounter
        k.time = item.time
        k.offset = nil
        keyframes[#keyframes + 1] = k
        selectedIds[k.id] = true
        selectedKeyframe = k
    end
    sortKeyframes()
    refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshPathVisualization()
end

---------------------------------------------------------------------
-- JSON PROJECT EXPORT / VALIDATED IMPORT
---------------------------------------------------------------------
local function serializeShot(shot)
    local data = {
        name = shot.name,
        duration = shot.duration,
        playbackSpeed = shot.playbackSpeed,
        loopPlayback = shot.loopPlayback,
        loopRegionEnabled = shot.loopRegionEnabled,
        loopRegionStart = shot.loopRegionStart,
        loopRegionEnd = shot.loopRegionEnd,
        reversePlayback = shot.reversePlayback,
        easingDefault = shot.easingDefault,
        defaultFOV = shot.defaultFOV,
        currentFOV = shot.currentFOV,
        cameraPose = (function()
            local p = shot.cameraCFrame.Position
            local rx, ry, rz = shot.cameraCFrame:ToOrientation()
            return { position = { x = p.X, y = p.Y, z = p.Z }, rotation = { x = math.deg(rx), y = math.deg(ry), z = math.deg(rz) } }
        end)(),
        cameraSettings = {
            movementSpeed = shot.camMoveSpeed,
            sensitivity = shot.camSensitivity,
            cameraMode = shot.cameraMode,
            orbitEnabled = shot.orbitEnabled,
            orbitDistance = shot.orbitDistance,
            orbitTarget = { x = shot.orbitTarget.X, y = shot.orbitTarget.Y, z = shot.orbitTarget.Z },
            orbitYaw = shot.orbitYaw,
            orbitPitch = shot.orbitPitch,
            lookAtEnabled = shot.lookAtEnabled,
            lookAtTarget = { x = shot.lookAtTarget.X, y = shot.lookAtTarget.Y, z = shot.lookAtTarget.Z },
        },
        keyframes = {},
    }
    for _, k in ipairs(shot.keyframes) do
        local p = k.cframe.Position
        local rx, ry, rz = k.cframe:ToOrientation()
        data.keyframes[#data.keyframes + 1] = {
            time = k.time,
            fov = k.fov,
            position = { x = p.X, y = p.Y, z = p.Z },
            rotation = { x = math.deg(rx), y = math.deg(ry), z = math.deg(rz) },
            easing = k.easing or "Smooth",
            interpolation = k.interpolation or "Linear",
        }
    end
    return data
end
local function exportProject()
    saveActiveShot()
    local data = {
        format = "FRAMEPLAY_PROJECT",
        version = 2,
        activeShot = currentShotIndex,
        timeline = { zoom = timelineZoom, snapEnabled = snapEnabled, snapFPS = snapFPS },
        cameraSettings = {
            movementSpeed = camMoveSpeed,
            sensitivity = camSensitivity,
            defaultFOV = defaultFOV,
            orbitEnabled = orbitEnabled,
            orbitDistance = orbitDistance,
            orbitTarget = { x = orbitTarget.X, y = orbitTarget.Y, z = orbitTarget.Z },
            orbitYaw = orbitYaw,
            orbitPitch = orbitPitch,
            lookAtEnabled = lookAtEnabled,
            lookAtTarget = { x = lookAtTarget.X, y = lookAtTarget.Y, z = lookAtTarget.Z },
            cameraMode = cameraMode,
        },
        playback = { countdown = countdownSeconds },
        shots = {},
        bookmarks = {},
    }
    for _, shot in ipairs(shots) do data.shots[#data.shots + 1] = serializeShot(shot) end
    for _, mark in ipairs(bookmarks) do
        local p = mark.cframe.Position
        local rx, ry, rz = mark.cframe:ToOrientation()
        data.bookmarks[#data.bookmarks + 1] = {
            name = mark.name, fov = mark.fov,
            position = { x = p.X, y = p.Y, z = p.Z },
            rotation = { x = math.deg(rx), y = math.deg(ry), z = math.deg(rz) },
        }
    end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
    if ok then
        UI.jsonBox.Text = encoded
        UI.settingsStatus.Text = "Exported " .. #shots .. " shot(s), " .. #keyframes .. " active keyframe(s)."
        setStatus("Project JSON exported.")
    else
        UI.settingsStatus.Text = "Export failed: " .. safeText(encoded, 100)
    end
end
local function validVectorTable(t)
    return type(t) == "table" and finiteNumber(t.x) and finiteNumber(t.y) and finiteNumber(t.z)
        and math.abs(t.x) <= 1000000 and math.abs(t.y) <= 1000000 and math.abs(t.z) <= 1000000
end
local function decodeShot(data, index)
    if type(data) ~= "table" or type(data.keyframes) ~= "table" then return nil, "Shot " .. index .. " is malformed." end
    if #data.keyframes > MAX_KEYFRAMES_PER_SHOT then return nil, "Shot " .. index .. " exceeds 1,000 keyframes." end
    local d = data.duration
    if not finiteNumber(d) or d < 0.1 or d > 3600 then return nil, "Shot " .. index .. " has invalid duration." end
    local speed = finiteNumber(data.playbackSpeed) and clamp(data.playbackSpeed, 0.05, 20) or 1
    local result = newShot(safeText(data.name or ("Shot " .. index), 48))
    result.duration = d
    result.playbackSpeed = speed
    result.loopPlayback = data.loopPlayback == true
    result.loopRegionEnabled = data.loopRegionEnabled == true
    result.loopRegionStart = finiteNumber(data.loopRegionStart) and clamp(data.loopRegionStart, 0, d) or 0
    result.loopRegionEnd = finiteNumber(data.loopRegionEnd) and clamp(data.loopRegionEnd, result.loopRegionStart, d) or d
    result.reversePlayback = data.reversePlayback == true
    result.easingDefault = table.find(EASING_MODES, data.easingDefault) and data.easingDefault or "Smooth"
    result.defaultFOV = finiteNumber(data.defaultFOV) and clamp(data.defaultFOV, 1, 169) or 70
    result.currentFOV = finiteNumber(data.currentFOV) and clamp(data.currentFOV, 1, 169) or result.defaultFOV
    if type(data.cameraPose) == "table" and validVectorTable(data.cameraPose.position) and validVectorTable(data.cameraPose.rotation)
        and math.abs(data.cameraPose.rotation.x) <= 36000 and math.abs(data.cameraPose.rotation.y) <= 36000 and math.abs(data.cameraPose.rotation.z) <= 36000 then
        local p, r = data.cameraPose.position, data.cameraPose.rotation
        result.cameraCFrame = CFrame.new(p.x, p.y, p.z) * CFrame.fromOrientation(math.rad(r.x), math.rad(r.y), math.rad(r.z))
    else
        result.cameraCFrame = freeCamCFrame
    end
    local shotCamera = type(data.cameraSettings) == "table" and data.cameraSettings or {}
    result.camMoveSpeed = finiteNumber(shotCamera.movementSpeed) and clamp(shotCamera.movementSpeed, 1, 1000) or camMoveSpeed
    result.camSensitivity = finiteNumber(shotCamera.sensitivity) and clamp(shotCamera.sensitivity, 0.01, 5) or camSensitivity
    result.cameraMode = table.find(CAMERA_MODES, shotCamera.cameraMode) and shotCamera.cameraMode or cameraMode
    result.orbitEnabled = shotCamera.orbitEnabled == true
    result.orbitDistance = finiteNumber(shotCamera.orbitDistance) and clamp(shotCamera.orbitDistance, 1, 10000) or orbitDistance
    result.orbitTarget = validVectorTable(shotCamera.orbitTarget) and Vector3.new(shotCamera.orbitTarget.x, shotCamera.orbitTarget.y, shotCamera.orbitTarget.z) or orbitTarget
    result.orbitYaw = finiteNumber(shotCamera.orbitYaw) and shotCamera.orbitYaw or orbitYaw
    result.orbitPitch = finiteNumber(shotCamera.orbitPitch) and clamp(shotCamera.orbitPitch, -1.5, 1.5) or orbitPitch
    result.lookAtEnabled = shotCamera.lookAtEnabled == true
    result.lookAtTarget = validVectorTable(shotCamera.lookAtTarget) and Vector3.new(shotCamera.lookAtTarget.x, shotCamera.lookAtTarget.y, shotCamera.lookAtTarget.z) or lookAtTarget
    local seenTimes = {}
    for keyIndex, entry in ipairs(data.keyframes) do
        if type(entry) ~= "table" or not finiteNumber(entry.time) or entry.time < 0 or entry.time > d
            or not finiteNumber(entry.fov) or not validVectorTable(entry.position) or not validVectorTable(entry.rotation) then
            return nil, string.format("Shot %d keyframe %d contains invalid data.", index, keyIndex)
        end
        if math.abs(entry.rotation.x) > 36000 or math.abs(entry.rotation.y) > 36000 or math.abs(entry.rotation.z) > 36000 then
            return nil, string.format("Shot %d keyframe %d has invalid rotation.", index, keyIndex)
        end
        local roundedTimeKey = string.format("%.5f", entry.time)
        if seenTimes[roundedTimeKey] then return nil, string.format("Shot %d has duplicate keyframe times.", index) end
        seenTimes[roundedTimeKey] = true
        keyframeIdCounter += 1
        local cf = CFrame.new(entry.position.x, entry.position.y, entry.position.z) * CFrame.fromOrientation(
            math.rad(entry.rotation.x), math.rad(entry.rotation.y), math.rad(entry.rotation.z)
        )
        result.keyframes[#result.keyframes + 1] = {
            id = keyframeIdCounter,
            time = entry.time,
            fov = clamp(entry.fov, 1, 169),
            cframe = cf,
            easing = table.find(EASING_MODES, entry.easing) and entry.easing or "Smooth",
            interpolation = table.find(INTERPOLATIONS, entry.interpolation) and entry.interpolation or "Linear",
        }
    end
    table.sort(result.keyframes, function(a, b) return a.time < b.time end)
    for index = 2, #result.keyframes do
        if result.keyframes[index].time - result.keyframes[index - 1].time < 0.001 then
            return nil, "Shot " .. index .. " has keyframes that are too close together."
        end
    end
    return result
end
local function decodeBookmark(entry, index)
    if type(entry) ~= "table" or not validVectorTable(entry.position) or not validVectorTable(entry.rotation) or not finiteNumber(entry.fov) then
        return nil, "Bookmark " .. index .. " is malformed."
    end
    local cf = CFrame.new(entry.position.x, entry.position.y, entry.position.z) * CFrame.fromOrientation(
        math.rad(entry.rotation.x), math.rad(entry.rotation.y), math.rad(entry.rotation.z)
    )
    return { name = safeText(entry.name or ("Bookmark " .. index), 48), cframe = cf, fov = clamp(entry.fov, 1, 169) }
end
local function importProject()
    local raw = UI.jsonBox.Text
    if raw == "" then UI.settingsStatus.Text = "Paste project JSON first."; return end
    local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(decoded) ~= "table" then UI.settingsStatus.Text = "Invalid JSON. Project unchanged."; return end

    -- Stage and validate every object before touching the active project.
    local stagedShots, stagedBookmarks = {}, {}
    if type(decoded.shots) == "table" then
        if #decoded.shots < 1 or #decoded.shots > 100 then UI.settingsStatus.Text = "Project must contain 1-100 shots."; return end
        for index, shotData in ipairs(decoded.shots) do
            local shot, err = decodeShot(shotData, index)
            if not shot then UI.settingsStatus.Text = err .. " Project unchanged."; return end
            stagedShots[#stagedShots + 1] = shot
        end
    elseif type(decoded.keyframes) == "table" then
        -- Backward compatibility with the original single-shot JSON format.
        local legacy = {
            name = "Shot 01", duration = finiteNumber(decoded.duration) and decoded.duration or 10,
            playbackSpeed = 1, loopPlayback = decoded.loop == true, reversePlayback = decoded.reverse == true,
            easingDefault = decoded.easing or "Smooth", defaultFOV = 70, currentFOV = 70,
            keyframes = decoded.keyframes,
        }
        local shot, err = decodeShot(legacy, 1)
        if not shot then UI.settingsStatus.Text = err .. " Project unchanged."; return end
        stagedShots[1] = shot
    else
        UI.settingsStatus.Text = "Missing shots/keyframes array. Project unchanged."; return
    end
    if type(decoded.bookmarks) == "table" then
        if #decoded.bookmarks > 200 then UI.settingsStatus.Text = "Too many bookmarks. Project unchanged."; return end
        for index, item in ipairs(decoded.bookmarks) do
            local mark, err = decodeBookmark(item, index)
            if not mark then UI.settingsStatus.Text = err .. " Project unchanged."; return end
            stagedBookmarks[#stagedBookmarks + 1] = mark
        end
    end

    local stagedTimeline = type(decoded.timeline) == "table" and decoded.timeline or {}
    local stagedCamera = type(decoded.cameraSettings) == "table" and decoded.cameraSettings or {}
    local stagedPlayback = type(decoded.playback) == "table" and decoded.playback or {}
    pushUndo()
    shots = stagedShots
    bookmarks = stagedBookmarks
    currentShotIndex = clamp(tonumber(decoded.activeShot) or 1, 1, #shots)
    loadShot(currentShotIndex)
    timelineZoom = finiteNumber(stagedTimeline.zoom) and clamp(stagedTimeline.zoom, 0.4, 4) or 1
    snapEnabled = stagedTimeline.snapEnabled ~= false
    snapFPS = (stagedTimeline.snapFPS == 24 or stagedTimeline.snapFPS == 30 or stagedTimeline.snapFPS == 60) and stagedTimeline.snapFPS or 30
    timelineSnapFrame = 1 / snapFPS
    camMoveSpeed = finiteNumber(stagedCamera.movementSpeed) and clamp(stagedCamera.movementSpeed, 1, 1000) or camMoveSpeed
    camSensitivity = finiteNumber(stagedCamera.sensitivity) and clamp(stagedCamera.sensitivity, 0.01, 5) or camSensitivity
    defaultFOV = finiteNumber(stagedCamera.defaultFOV) and clamp(stagedCamera.defaultFOV, 1, 169) or defaultFOV
    orbitEnabled = stagedCamera.orbitEnabled == true
    orbitDistance = finiteNumber(stagedCamera.orbitDistance) and clamp(stagedCamera.orbitDistance, 1, 10000) or orbitDistance
    if validVectorTable(stagedCamera.orbitTarget) then orbitTarget = Vector3.new(stagedCamera.orbitTarget.x, stagedCamera.orbitTarget.y, stagedCamera.orbitTarget.z) end
    orbitYaw = finiteNumber(stagedCamera.orbitYaw) and stagedCamera.orbitYaw or orbitYaw
    orbitPitch = finiteNumber(stagedCamera.orbitPitch) and clamp(stagedCamera.orbitPitch, -1.5, 1.5) or orbitPitch
    lookAtEnabled = stagedCamera.lookAtEnabled == true
    if validVectorTable(stagedCamera.lookAtTarget) then lookAtTarget = Vector3.new(stagedCamera.lookAtTarget.x, stagedCamera.lookAtTarget.y, stagedCamera.lookAtTarget.z) end
    if table.find(CAMERA_MODES, stagedCamera.cameraMode) then cameraMode = stagedCamera.cameraMode; cameraModeIndex = table.find(CAMERA_MODES, cameraMode) end
    countdownSeconds = finiteNumber(stagedPlayback.countdown) and clamp(math.floor(stagedPlayback.countdown), 0, 15) or countdownSeconds

    UI.camSpeedBox.Text = tostring(camMoveSpeed); UI.sensitivityBox.Text = tostring(camSensitivity)
    UI.defaultFovBox.Text = tostring(defaultFOV); UI.orbitDistanceBox.Text = tostring(orbitDistance)
    UI.orbitTargetXBox.Text = tostring(orbitTarget.X); UI.orbitTargetYBox.Text = tostring(orbitTarget.Y); UI.orbitTargetZBox.Text = tostring(orbitTarget.Z)
    UI.lookTargetXBox.Text = tostring(lookAtTarget.X); UI.lookTargetYBox.Text = tostring(lookAtTarget.Y); UI.lookTargetZBox.Text = tostring(lookAtTarget.Z)
    UI.countdownBox.Text = tostring(countdownSeconds)
    UI.modeBtn.Text = "MODE: " .. string.upper(cameraMode)
    UI.orbitToggleBtn.Text = "ORBIT: " .. (orbitEnabled and "ON" or "OFF")
    UI.lookAtToggleBtn.Text = "LOOK AT TARGET: " .. (lookAtEnabled and "ON" or "OFF")
    saveActiveShot()
    updateShotControls(); updateBookmarkControls(); refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshRuler(); seekTo(0); refreshPathVisualization()
    UI.settingsStatus.Text = "Imported " .. #shots .. " shot(s), " .. #bookmarks .. " bookmark(s)."
    setStatus("Project imported successfully.")
end

---------------------------------------------------------------------
-- PLAYHEAD / NAVIGATION
---------------------------------------------------------------------
local function previousKeyframe()
    local best
    for _, k in ipairs(keyframes) do if k.time < currentTime - 0.0001 and (not best or k.time > best.time) then best = k end end
    if not best then best = keyframes[1] end
    if best then selectKeyframe(best); seekTo(best.time) end
end
local function nextKeyframe()
    local best
    for _, k in ipairs(keyframes) do if k.time > currentTime + 0.0001 and (not best or k.time < best.time) then best = k end end
    if not best then best = keyframes[#keyframes] end
    if best then selectKeyframe(best); seekTo(best.time) end
end
local function frameStep(direction)
    seekTo(currentTime + direction / math.max(1, snapFPS))
end

---------------------------------------------------------------------
-- CAMERA BOOKMARKS
---------------------------------------------------------------------
local function saveBookmark()
    pushUndo()
    local name = safeText(UI.bookmarkNameBox.Text, 48)
    if name == "" then name = "Bookmark " .. tostring(#bookmarks + 1) end
    bookmarks[#bookmarks + 1] = { name = name, cframe = freeCamCFrame, fov = currentFOV }
    selectedBookmark = #bookmarks
    updateBookmarkControls()
    setStatus("Bookmark saved.")
end
local function applyBookmark()
    local mark = bookmarks[selectedBookmark]
    if not mark then return end
    freeCamCFrame = mark.cframe
    currentFOV = mark.fov
    if camera then camera.CFrame = freeCamCFrame; camera.FieldOfView = currentFOV end
    if orbitEnabled then syncOrbitFromCamera() end
    setStatus("Bookmark applied.")
end
local function renameBookmark()
    local mark = bookmarks[selectedBookmark]
    if not mark then return end
    pushUndo()
    mark.name = safeText(UI.bookmarkNameBox.Text, 48)
    if mark.name == "" then mark.name = "Bookmark " .. selectedBookmark end
    updateBookmarkControls()
end
local function deleteBookmark()
    if not bookmarks[selectedBookmark] then return end
    pushUndo()
    table.remove(bookmarks, selectedBookmark)
    selectedBookmark = clamp(selectedBookmark, 1, math.max(1, #bookmarks))
    updateBookmarkControls()
end

---------------------------------------------------------------------
-- UI BUTTON WIRING
---------------------------------------------------------------------
connect(UI.playBtn.Activated, togglePlayback)
connect(UI.pauseBtn.Activated, function() if isPlaying then isPaused = true end end)
connect(UI.stopBtn.Activated, stopPlayback)
connect(UI.addBtn.Activated, function() addKeyframe(currentTime, freeCamCFrame, currentFOV) end)
connect(UI.deleteBtn.Activated, deleteSelectedKeyframes)
connect(UI.undoBtn.Activated, undo)
connect(UI.redoBtn.Activated, redo)
connect(UI.copyBtn.Activated, copySelected)
connect(UI.pasteBtn.Activated, pasteCopied)
connect(UI.modeBtn.Activated, function()
    cameraModeIndex = cameraModeIndex % #CAMERA_MODES + 1
    cameraMode = CAMERA_MODES[cameraModeIndex]
    orbitEnabled = cameraMode == "Orbit"
    if orbitEnabled then syncOrbitFromCamera() end
    UI.modeBtn.Text = "MODE: " .. string.upper(cameraMode)
    UI.orbitToggleBtn.Text = "ORBIT: " .. (orbitEnabled and "ON" or "OFF")
    saveActiveShot()
end)
connect(UI.panelBtn.Activated, function() inspectorVisible = not inspectorVisible; relayout() end)
connect(UI.settingsBtn.Activated, function() UI.settingsBackdrop.Visible = not UI.settingsBackdrop.Visible; UI.helpBackdrop.Visible = false end)
connect(UI.helpBtn.Activated, function() UI.helpBackdrop.Visible = not UI.helpBackdrop.Visible; UI.settingsBackdrop.Visible = false end)
connect(UI.helpClose.Activated, function() UI.helpBackdrop.Visible = false end)
connect(UI.closeBtn.Activated, function()
    cancelCountdown()
    if isPlaying then stopPlayback() end
    editorOpen = false; editorHidden = false
    UI.root.Visible = false
    if renderConnection then renderConnection:Disconnect(); renderConnection = nil end
    restorePlaybackGuis(); restoreCameraSnapshot()
    disconnectBucket(temporaryConnections)
    moveState = { forward = false, backward = false, left = false, right = false, up = false, down = false }
    resetJoystick(); lookInput = nil; lastLookPosition = nil
    rightMouseDown = false; shiftHeld = false; ctrlHeld = false
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
    if pathFolder then for _, child in ipairs(pathFolder:GetChildren()) do child:Destroy() end end
    setStatus("Editor closed.")
end)
connect(UI.settingsClose.Activated, function() UI.settingsBackdrop.Visible = false end)
connect(UI.prevKeyBtn.Activated, previousKeyframe)
connect(UI.nextKeyBtn.Activated, nextKeyframe)
connect(UI.prevFrameBtn.Activated, function() frameStep(-1) end)
connect(UI.nextFrameBtn.Activated, function() frameStep(1) end)
connect(UI.restartTimelineBtn.Activated, restartPlayback)
connect(UI.zoomOutBtn.Activated, function()
    timelineZoom = clamp(timelineZoom / 1.25, 0.4, 4); refreshRuler(); refreshTimelineMarkers()
end)
connect(UI.zoomInBtn.Activated, function()
    timelineZoom = clamp(timelineZoom * 1.25, 0.4, 4); refreshRuler(); refreshTimelineMarkers()
end)
connect(UI.loopBtn.Activated, function()
    loopPlayback = not loopPlayback
    UI.loopBtn.Text = loopPlayback and "LOOP ON" or "LOOP OFF"
    saveActiveShot()
end)
connect(UI.loopInBtn.Activated, function()
    pushUndo()
    loopRegionStart = clamp(currentTime, 0, duration)
    if loopRegionEnd <= loopRegionStart then loopRegionEnd = duration end
    loopRegionEnabled = true
    UI.regionBtn.Text = "REGION ON"
    saveActiveShot()
    setStatus("Loop in: " .. string.format("%.2fs", loopRegionStart))
end)
connect(UI.loopOutBtn.Activated, function()
    pushUndo()
    loopRegionEnd = clamp(currentTime, 0, duration)
    if loopRegionEnd <= loopRegionStart then loopRegionStart = 0 end
    loopRegionEnabled = true
    UI.regionBtn.Text = "REGION ON"
    saveActiveShot()
    setStatus("Loop out: " .. string.format("%.2fs", loopRegionEnd))
end)
connect(UI.regionBtn.Activated, function()
    pushUndo()
    loopRegionEnabled = not loopRegionEnabled
    UI.regionBtn.Text = loopRegionEnabled and "REGION ON" or "REGION OFF"
    saveActiveShot()
end)
connect(UI.reverseBtn.Activated, function()
    reversePlayback = not reversePlayback
    UI.reverseBtn.Text = reversePlayback and "REVERSE ON" or "REVERSE OFF"
    saveActiveShot()
end)
connect(UI.snapBtn.Activated, function()
    if not snapEnabled then
        snapEnabled = true
        snapFPS = 24
    elseif snapFPS == 24 then snapFPS = 30
    elseif snapFPS == 30 then snapFPS = 60
    else snapEnabled = false end
    timelineSnapFrame = 1 / snapFPS
    UI.snapBtn.Text = snapEnabled and ("SNAP " .. snapFPS) or "SNAP OFF"
end)
connect(UI.durationBox.FocusLost, function()
    local value = tonumber(UI.durationBox.Text)
    if not finiteNumber(value) or value < 0.1 or value > 3600 then UI.durationBox.Text = tostring(duration); setStatus("Duration must be 0.1-3600 seconds."); return end
    local lastTime = 0
    for _, k in ipairs(keyframes) do lastTime = math.max(lastTime, k.time) end
    if value < lastTime then
        UI.durationBox.Text = tostring(duration)
        setStatus(string.format("Duration must be at least %.3fs to keep every keyframe.", lastTime))
        return
    end
    pushUndo()
    duration = value
    loopRegionStart = clamp(loopRegionStart, 0, duration)
    loopRegionEnd = clamp(loopRegionEnd, loopRegionStart, duration)
    currentTime = clamp(currentTime, 0, duration)
    saveActiveShot(); refreshRuler(); refreshTimelineMarkers(); seekTo(currentTime)
end)
connect(UI.speedBox.FocusLost, function()
    local value = tonumber(UI.speedBox.Text)
    if finiteNumber(value) and value > 0 then playbackSpeed = clamp(value, 0.05, 20); saveActiveShot() end
    UI.speedBox.Text = tostring(playbackSpeed)
end)
connect(UI.segmentEaseBtn.Activated, function()
    if not selectedKeyframe then return end
    local index = table.find(EASING_MODES, selectedKeyframe.easing or easingDefault) or 1
    pushUndo()
    selectedKeyframe.easing = EASING_MODES[index % #EASING_MODES + 1]
    refreshSelectedPanel()
end)
connect(UI.interpolationBtn.Activated, function()
    if not selectedKeyframe then return end
    local index = table.find(INTERPOLATIONS, selectedKeyframe.interpolation or "Linear") or 1
    pushUndo()
    selectedKeyframe.interpolation = INTERPOLATIONS[index % #INTERPOLATIONS + 1]
    refreshSelectedPanel()
end)
connect(UI.applyFieldsBtn.Activated, function()
    if not selectedKeyframe then return end
    local k = selectedKeyframe
    local function value(box, fallback)
        local n = tonumber(box.Text)
        return finiteNumber(n) and n or fallback
    end
    local p = Vector3.new(value(UI.posXBox, k.cframe.Position.X), value(UI.posYBox, k.cframe.Position.Y), value(UI.posZBox, k.cframe.Position.Z))
    if math.abs(p.X) > 1000000 or math.abs(p.Y) > 1000000 or math.abs(p.Z) > 1000000 then setStatus("Position is outside the supported range."); return end
    local rx = value(UI.rotXBox, 0); local ry = value(UI.rotYBox, 0); local rz = value(UI.rotZBox, 0)
    local fov = value(UI.fovBox, k.fov); local newTime = clamp(value(UI.timeBox, k.time), 0, duration)
    if math.abs(rx) > 36000 or math.abs(ry) > 36000 or math.abs(rz) > 36000 then setStatus("Rotation is outside the supported range."); return end
    local collision = findKeyframeNear(newTime, { [k.id] = true })
    if collision then setStatus("Time change blocked: another keyframe is there."); return end
    pushUndo()
    k.cframe = CFrame.new(p) * CFrame.fromOrientation(math.rad(rx), math.rad(ry), math.rad(rz))
    k.fov = clamp(fov, 1, 169)
    k.time = newTime
    sortKeyframes()
    refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshPathVisualization(); seekTo(currentTime)
end)
connect(UI.snapCameraBtn.Activated, function()
    if not selectedKeyframe then return end
    pushUndo()
    selectedKeyframe.cframe = freeCamCFrame
    selectedKeyframe.fov = currentFOV
    refreshSelectedPanel(); refreshTimelineMarkers(); refreshPathVisualization()
end)
connect(UI.duplicateBtn.Activated, duplicateSelectedKeyframes)
connect(UI.deleteSelectedBtn.Activated, deleteSelectedKeyframes)
local clearAllArmed = false
local clearAllToken = 0
connect(UI.clearAllBtn.Activated, function()
    if #keyframes == 0 then return end
    if not clearAllArmed then
        clearAllArmed = true
        clearAllToken += 1
        local token = clearAllToken
        UI.clearAllBtn.Text = "TAP AGAIN TO CLEAR"
        setStatus("Confirm clear within 3 seconds.")
        task.delay(3, function()
            if cleanedUp or token ~= clearAllToken then return end
            clearAllArmed = false
            if UI.clearAllBtn and UI.clearAllBtn.Parent then UI.clearAllBtn.Text = "CLEAR SHOT KEYFRAMES" end
        end)
    else
        clearAllToken += 1
        clearAllArmed = false
        UI.clearAllBtn.Text = "CLEAR SHOT KEYFRAMES"
        clearAllKeyframes()
    end
end)

-- Camera settings / orbit / look-at.
connect(UI.orbitToggleBtn.Activated, function()
    orbitEnabled = not orbitEnabled
    if orbitEnabled then
        syncOrbitFromCamera()
        cameraMode = "Orbit"
        cameraModeIndex = table.find(CAMERA_MODES, "Orbit")
    elseif cameraMode == "Orbit" then
        cameraMode = "Free"
        cameraModeIndex = table.find(CAMERA_MODES, "Free")
    end
    UI.orbitToggleBtn.Text = "ORBIT: " .. (orbitEnabled and "ON" or "OFF")
    UI.modeBtn.Text = "MODE: " .. string.upper(cameraMode)
    saveActiveShot()
end)
connect(UI.lookAtToggleBtn.Activated, function()
    lookAtEnabled = not lookAtEnabled
    UI.lookAtToggleBtn.Text = "LOOK AT TARGET: " .. (lookAtEnabled and "ON" or "OFF")
    saveActiveShot()
end)
connect(UI.applyCameraSettingsBtn.Activated, function()
    local speed = tonumber(UI.camSpeedBox.Text)
    local sensitivity = tonumber(UI.sensitivityBox.Text)
    local fov = tonumber(UI.defaultFovBox.Text)
    local distance = tonumber(UI.orbitDistanceBox.Text)
    local otx, oty, otz = tonumber(UI.orbitTargetXBox.Text), tonumber(UI.orbitTargetYBox.Text), tonumber(UI.orbitTargetZBox.Text)
    local ltx, lty, ltz = tonumber(UI.lookTargetXBox.Text), tonumber(UI.lookTargetYBox.Text), tonumber(UI.lookTargetZBox.Text)
    local roll = tonumber(UI.rollBox.Text)
    if finiteNumber(speed) then camMoveSpeed = clamp(speed, 1, 1000) end
    if finiteNumber(sensitivity) then camSensitivity = clamp(sensitivity, 0.01, 5) end
    if finiteNumber(fov) then defaultFOV = clamp(fov, 1, 169); currentFOV = defaultFOV end
    if finiteNumber(distance) then orbitDistance = clamp(distance, 1, 10000) end
    if finiteNumber(otx) and finiteNumber(oty) and finiteNumber(otz) then orbitTarget = Vector3.new(otx, oty, otz) end
    if finiteNumber(ltx) and finiteNumber(lty) and finiteNumber(ltz) then lookAtTarget = Vector3.new(ltx, lty, ltz) end
    if finiteNumber(roll) then
        local p = freeCamCFrame.Position
        local rx, ry = freeCamCFrame:ToOrientation()
        freeCamCFrame = CFrame.new(p) * CFrame.fromOrientation(rx, ry, math.rad(clamp(roll, -180, 180)))
    end
    if orbitEnabled then freeCamCFrame = orbitCFrame() end
    if camera then camera.CFrame = freeCamCFrame; camera.FieldOfView = currentFOV end
    saveActiveShot()
    setStatus("Camera settings applied.")
end)

-- Guide toggles.
local function toggleGuide(key)
    guideSettings[key] = not guideSettings[key]
    updateGuideVisibility()
end
connect(UI.thirdsBtn.Activated, function() toggleGuide("thirds") end)
connect(UI.centerBtn.Activated, function() toggleGuide("center") end)
connect(UI.safe169Btn.Activated, function() toggleGuide("safe169") end)
connect(UI.safe43Btn.Activated, function() toggleGuide("safe43") end)
connect(UI.safe235Btn.Activated, function() toggleGuide("safe235") end)
connect(UI.pathToggleBtn.Activated, function()
    showPath = not showPath
    UI.pathToggleBtn.Text = "CAMERA PATH: " .. (showPath and "ON" or "OFF")
    refreshPathVisualization()
end)

-- Shot manager.
connect(UI.newShotBtn.Activated, function() createShot(false) end)
connect(UI.duplicateShotBtn.Activated, function() createShot(true) end)
connect(UI.renameShotBtn.Activated, function()
    local name = safeText(UI.shotNameBox.Text, 48)
    if name == "" then return end
    pushUndo(); shots[currentShotIndex].name = name; updateShotControls()
end)
connect(UI.deleteShotBtn.Activated, deleteShot)
connect(UI.previousShotBtn.Activated, function() switchShot(currentShotIndex - 1) end)
connect(UI.nextShotBtn.Activated, function() switchShot(currentShotIndex + 1) end)

-- Bookmarks.
connect(UI.saveBookmarkBtn.Activated, saveBookmark)
connect(UI.applyBookmarkBtn.Activated, applyBookmark)
connect(UI.renameBookmarkBtn.Activated, renameBookmark)
connect(UI.deleteBookmarkBtn.Activated, deleteBookmark)
connect(UI.nextBookmarkBtn.Activated, function()
    if #bookmarks > 0 then selectedBookmark = selectedBookmark % #bookmarks + 1; updateBookmarkControls() end
end)

connect(UI.exportBtn.Activated, exportProject)
connect(UI.importBtn.Activated, importProject)

---------------------------------------------------------------------
-- TIMELINE SCRUBBING / INPUT TRACKING
---------------------------------------------------------------------
local scrubbingInput = nil
local function snapTimelineTime(value)
    if snapEnabled then return clamp(round(value / timelineSnapFrame) * timelineSnapFrame, 0, duration) end
    return value
end
connect(UI.markerLane.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        scrubbingInput = input
        seekTo(snapTimelineTime(screenToTimelineTime(input.Position.X)))
    end
end)
connect(UserInputService.InputChanged, function(input)
    if scrubbingInput and (input == scrubbingInput or (scrubbingInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)) then
        seekTo(snapTimelineTime(screenToTimelineTime(input.Position.X)))
    end
end)
connect(UserInputService.InputEnded, function(input)
    if scrubbingInput and (input == scrubbingInput or (scrubbingInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)) then scrubbingInput = nil end
end)

---------------------------------------------------------------------
-- MOBILE TOUCH INPUT: JOYSTICK AND LOOK USE INDEPENDENT POINTERS
---------------------------------------------------------------------
resetJoystick = function()
    joystickInput = nil
    joystickDir = Vector3.zero
    if UI.joystickKnob then UI.joystickKnob.Position = UDim2.new(0.5, 0, 0.5, 0) end
end
local function updateJoystick(position)
    local center = UI.joystickBase.AbsolutePosition + UI.joystickBase.AbsoluteSize / 2
    local offset = Vector2.new(position.X, position.Y) - center
    local radius = UI.joystickBase.AbsoluteSize.X * 0.38
    local magnitude = math.min(offset.Magnitude, radius)
    local direction = offset.Magnitude > 0 and offset.Unit * magnitude or Vector2.zero
    UI.joystickKnob.Position = UDim2.new(0.5, direction.X, 0.5, direction.Y)
    joystickDir = Vector3.new(direction.X / math.max(radius, 1), 0, direction.Y / math.max(radius, 1))
end
connect(UI.joystickBase.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        if not joystickInput then joystickInput = input; updateJoystick(input.Position) end
    end
end)
connect(UI.touchCatcher.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.Touch and editorOpen and not editorHidden and not isPlaying then
        if not lookInput then lookInput = input; lastLookPosition = input.Position end
    end
end)
local function bindVerticalButton(button, stateName)
    connect(button.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            if stateName == "up" then upHeldInput = input; moveState.up = true
            else downHeldInput = input; moveState.down = true end
        end
    end)
end
bindVerticalButton(UI.upBtn, "up")
bindVerticalButton(UI.downBtn, "down")

connect(UserInputService.InputChanged, function(input)
    if joystickInput and (input == joystickInput or (joystickInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)) then
        updateJoystick(input.Position)
    end
    if lookInput and input == lookInput then
        if lastLookPosition and editorOpen and not editorHidden and not isPlaying then
            local delta = input.Position - lastLookPosition
            updateFreeCameraLook(delta)
        end
        lastLookPosition = input.Position
    end
end)
connect(UserInputService.InputEnded, function(input)
    if joystickInput and (input == joystickInput or (joystickInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)) then resetJoystick() end
    if lookInput and input == lookInput then lookInput = nil; lastLookPosition = nil end
    if upHeldInput and (input == upHeldInput or (upHeldInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)) then upHeldInput = nil; moveState.up = false end
    if downHeldInput and (input == downHeldInput or (downHeldInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)) then downHeldInput = nil; moveState.down = false end
end)

---------------------------------------------------------------------
-- KEYBOARD / MOUSE CONTROLS
---------------------------------------------------------------------
local playbackTouches = {}
connect(UserInputService.InputBegan, function(input, gameProcessed)
    if isPlaying and input.UserInputType == Enum.UserInputType.Touch then
        playbackTouches[input] = true
        local count = 0
        for _ in pairs(playbackTouches) do count += 1 end
        if count >= 2 then table.clear(playbackTouches); stopPlayback() end
        return
    end
    if not editorOpen or editorHidden or gameProcessed then return end
    if input.UserInputType == Enum.UserInputType.Keyboard then
        local key = input.KeyCode
        local focusedTextBox = UserInputService:GetFocusedTextBox()
        if key == Enum.KeyCode.Escape then
            if countdownActive then cancelCountdown() elseif isPlaying then stopPlayback() end
            return
        end
        if focusedTextBox then return end
        if key == Enum.KeyCode.Space then togglePlayback(); return
        elseif key == Enum.KeyCode.LeftControl or key == Enum.KeyCode.RightControl then ctrlHeld = true; return
        elseif key == Enum.KeyCode.LeftShift or key == Enum.KeyCode.RightShift then shiftHeld = true; return end
        if isPlaying then return end
        if key == Enum.KeyCode.W then moveState.forward = true
        elseif key == Enum.KeyCode.S then moveState.backward = true
        elseif key == Enum.KeyCode.A then moveState.left = true
        elseif key == Enum.KeyCode.D then if ctrlHeld then duplicateSelectedKeyframes() else moveState.right = true end
        elseif key == Enum.KeyCode.E then moveState.up = true
        elseif key == Enum.KeyCode.Q then moveState.down = true
        elseif key == Enum.KeyCode.Delete or key == Enum.KeyCode.Backspace then deleteSelectedKeyframes()
        elseif key == Enum.KeyCode.C and ctrlHeld then copySelected()
        elseif key == Enum.KeyCode.V and ctrlHeld then pasteCopied()
        elseif key == Enum.KeyCode.Z and ctrlHeld then undo()
        elseif key == Enum.KeyCode.Y and ctrlHeld then redo()
        elseif key == Enum.KeyCode.Left then frameStep(-1)
        elseif key == Enum.KeyCode.Right then frameStep(1) end
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 and not isPlaying then
        rightMouseDown = true
        pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition end)
        UserInputService.MouseIconEnabled = false
    end
end)
connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.Touch then playbackTouches[input] = nil end
    if input.UserInputType == Enum.UserInputType.Keyboard then
        local key = input.KeyCode
        if key == Enum.KeyCode.W then moveState.forward = false
        elseif key == Enum.KeyCode.S then moveState.backward = false
        elseif key == Enum.KeyCode.A then moveState.left = false
        elseif key == Enum.KeyCode.D then moveState.right = false
        elseif key == Enum.KeyCode.E then moveState.up = false
        elseif key == Enum.KeyCode.Q then moveState.down = false
        elseif key == Enum.KeyCode.LeftShift or key == Enum.KeyCode.RightShift then shiftHeld = false
        elseif key == Enum.KeyCode.LeftControl or key == Enum.KeyCode.RightControl then ctrlHeld = false end
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        rightMouseDown = false
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
    end
end)
connect(UserInputService.InputChanged, function(input)
    if not editorOpen or editorHidden or isPlaying then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement and rightMouseDown then
        updateFreeCameraLook(input.Delta)
    elseif input.UserInputType == Enum.UserInputType.MouseWheel then
        if orbitEnabled or cameraMode == "Orbit" then
            orbitDistance = clamp(orbitDistance - input.Position.Z * 2, 1, 10000)
            UI.orbitDistanceBox.Text = tostring(round(orbitDistance, 2))
        else
            camMoveSpeed = clamp(camMoveSpeed + input.Position.Z * 5, 1, 1000)
            UI.camSpeedBox.Text = tostring(camMoveSpeed)
            saveActiveShot()
        end
    end
end)

---------------------------------------------------------------------
-- EDITOR OPEN / HIDE / CLOSE / REPLAY COMMAND
---------------------------------------------------------------------
local function openEditor()
    if editorOpen then
        editorHidden = false
        UI.root.Visible = true
        return
    end
    editorOpen = true
    editorHidden = false
    camera = Workspace.CurrentCamera
    cameraSnapshot = captureCamera(camera)
    if camera then
        freeCamCFrame = camera.CFrame
        currentFOV = camera.FieldOfView
    end
    forceScriptable()
    if camera then camera.CFrame = freeCamCFrame; camera.FieldOfView = currentFOV end
    saveActiveShot()
    UI.root.Visible = true
    if not renderConnection then renderConnection = RunService.RenderStepped:Connect(function(dt)
        if cleanedUp or not editorOpen then return end
        camera = Workspace.CurrentCamera or camera
        if not camera then return end
        if camera.CameraType ~= Enum.CameraType.Scriptable then forceScriptable() end
        if isPlaying then
            if not isPaused then
                local step = dt * playbackSpeed * (reversePlayback and -1 or 1)
                currentTime += step
                local loopStart = loopRegionEnabled and loopRegionStart or 0
                local loopEnd = loopRegionEnabled and loopRegionEnd or duration
                if loopEnd <= loopStart then loopStart = 0; loopEnd = duration end
                if reversePlayback and currentTime <= loopStart then
                    if loopPlayback then currentTime = loopEnd - ((loopStart - currentTime) % math.max(loopEnd - loopStart, 0.0001))
                    else currentTime = loopStart; finishPlayback() end
                elseif not reversePlayback and currentTime >= loopEnd then
                    if loopPlayback then currentTime = loopStart + ((currentTime - loopStart) % math.max(loopEnd - loopStart, 0.0001))
                    else currentTime = loopEnd; finishPlayback() end
                end
            end
            local cf, fov = getCameraStateAtTime(currentTime)
            if cf then
                cf = applyLookAt(cf)
                camera.CFrame = cf
                camera.FieldOfView = clamp(fov or currentFOV, 1, 169)
                freeCamCFrame = cf
                currentFOV = camera.FieldOfView
            end
        elseif not UserInputService:GetFocusedTextBox() and not editorHidden then
            local move = Vector3.zero
            if cameraMode == "Free" then
                if moveState.forward then move += freeCamCFrame.LookVector end
                if moveState.backward then move -= freeCamCFrame.LookVector end
                if moveState.left then move -= freeCamCFrame.RightVector end
                if moveState.right then move += freeCamCFrame.RightVector end
            elseif cameraMode == "Dolly" then
                if moveState.forward then move += freeCamCFrame.LookVector end
                if moveState.backward then move -= freeCamCFrame.LookVector end
            elseif cameraMode == "Truck" then
                if moveState.left then move -= freeCamCFrame.RightVector end
                if moveState.right then move += freeCamCFrame.RightVector end
            elseif cameraMode == "Pedestal" then
                -- Vertical translation is handled below.
            elseif cameraMode == "Orbit" or orbitEnabled then
                if moveState.forward then orbitDistance = math.max(1, orbitDistance - camMoveSpeed * dt) end
                if moveState.backward then orbitDistance += camMoveSpeed * dt end
            end
            if joystickDir.Magnitude > 0 then
                local strafe = freeCamCFrame.RightVector * joystickDir.X
                local forward = freeCamCFrame.LookVector * -joystickDir.Z
                if cameraMode == "Dolly" then strafe = Vector3.zero
                elseif cameraMode == "Truck" then forward = Vector3.zero
                elseif cameraMode == "Pedestal" then strafe = Vector3.zero; forward = Vector3.zero end
                move += strafe + forward
            end
            local vertical = 0
            if moveState.up then vertical += 1 end
            if moveState.down then vertical -= 1 end
            if cameraMode == "Free" or cameraMode == "Pedestal" then
                move += Vector3.new(0, vertical, 0)
            end
            if move.Magnitude > 1 then move = move.Unit end
            local speed = camMoveSpeed * (shiftHeld and 2.5 or 1)
            if move.Magnitude > 0 then
                if orbitEnabled or cameraMode == "Orbit" then
                    orbitTarget += move * speed * dt
                else
                    freeCamCFrame = freeCamCFrame + move * speed * dt
                end
            end
            if orbitEnabled or cameraMode == "Orbit" then freeCamCFrame = orbitCFrame() end
            freeCamCFrame = applyLookAt(freeCamCFrame)
            camera.CFrame = freeCamCFrame
            camera.FieldOfView = currentFOV
        end
        updatePlayheadVisual(); updateTimeDisplays()
    end) end
    refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshRuler(); updateShotControls(); updateBookmarkControls(); updateGuideVisibility(); refreshPathVisualization()
end
local function hideEditor()
    if not editorOpen or editorHidden then return end
    editorHidden = true
    UI.settingsBackdrop.Visible = false
    UI.helpBackdrop.Visible = false
    moveState = { forward = false, backward = false, left = false, right = false, up = false, down = false }
    resetJoystick(); lookInput = nil; lastLookPosition = nil
    rightMouseDown = false; shiftHeld = false; ctrlHeld = false
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
    UI.root.Visible = false
end
local function showEditor()
    if not editorOpen then openEditor(); return end
    editorHidden = false
    UI.root.Visible = true
    refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); updatePlayheadVisual()
end
local lastReplayAt = 0
local function toggleReplay()
    if clock() - lastReplayAt < 0.4 then return end
    lastReplayAt = clock()
    if not editorOpen then openEditor() elseif editorHidden then showEditor() else hideEditor() end
end

---------------------------------------------------------------------
-- WORKSPACE CAMERA CHANGES / RESPAWN
---------------------------------------------------------------------
connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
    local newCamera = Workspace.CurrentCamera
    if not newCamera then return end
    camera = newCamera
    if editorOpen then
        cameraSnapshot = captureCamera(newCamera)
        forceScriptable()
        if isPlaying then
            local cf, fov = getCameraStateAtTime(currentTime)
            if cf then camera.CFrame = applyLookAt(cf); camera.FieldOfView = fov or currentFOV end
        else
            camera.CFrame = freeCamCFrame
            camera.FieldOfView = currentFOV
        end
    end
end)
connect(player.CharacterAdded, function(character)
    task.defer(function()
        local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
        if editorOpen then
            camera = Workspace.CurrentCamera
            if cameraSnapshot and cameraSnapshot.camera == camera and humanoid then
                cameraSnapshot.subject = humanoid
            end
            forceScriptable()
            if camera then camera.CFrame = freeCamCFrame; camera.FieldOfView = currentFOV end
        end
    end)
end)

---------------------------------------------------------------------
-- CHAT COMMANDS
---------------------------------------------------------------------
local replayCommand
pcall(function()
    local existing = TextChatService:FindFirstChild("FramePlayReplayCommand")
    if existing then existing:Destroy() end
    replayCommand = Instance.new("TextChatCommand")
    replayCommand.Name = "FramePlayReplayCommand"
    replayCommand.PrimaryAlias = "/replay"
    replayCommand.SecondaryAlias = "/frameplay"
    replayCommand.AutocompleteVisible = true
    replayCommand.Triggered:Connect(function(source)
        if source and source.UserId == player.UserId then toggleReplay() end
    end)
    replayCommand.Parent = TextChatService
end)
pcall(function()
    connect(player.Chatted, function(message)
        if type(message) == "string" then
            local normalized = message:lower():match("^%s*(.-)%s*$")
            if normalized == "/replay" or normalized == "/frameplay" then toggleReplay() end
        end
    end)
end)
pcall(function()
    connect(TextChatService.SendingMessage, function(message)
        local source = message and message.TextSource
        local text = message and message.Text
        if source and source.UserId == player.UserId and type(text) == "string" then
            local normalized = text:lower():match("^%s*(.-)%s*$")
            if normalized == "/replay" or normalized == "/frameplay" then toggleReplay() end
        end
    end)
end)

---------------------------------------------------------------------
-- CLEANUP / SCRIPT RE-EXECUTION
---------------------------------------------------------------------
local function cleanup()
    if cleanedUp then return end
    cleanedUp = true
    clearAllToken += 1
    cancelCountdown()
    if isPlaying then finishPlayback() end
    restorePlaybackGuis()
    editorOpen = false
    if renderConnection then renderConnection:Disconnect(); renderConnection = nil end
    disconnectBucket(markerConnections)
    disconnectBucket(listConnections)
    disconnectBucket(temporaryConnections)
    disconnectBucket(connections)
    if replayCommand and replayCommand.Parent then replayCommand:Destroy() end
    if pathFolder and pathFolder.Parent then pathFolder:Destroy() end
    if UI.gui and UI.gui.Parent then UI.gui:Destroy() end
    restoreCameraSnapshot()
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
end
connect(shutdownSignal.Event, cleanup)
if script then pcall(function() connect(script.Destroying, cleanup) end) end
connect(player.AncestryChanged, function(_, parent)
    if not parent then cleanup() end
end)

---------------------------------------------------------------------
-- INITIALIZE
---------------------------------------------------------------------
loadShot(1)
UI.loopBtn.Text = loopPlayback and "LOOP ON" or "LOOP OFF"
UI.regionBtn.Text = loopRegionEnabled and "REGION ON" or "REGION OFF"
UI.reverseBtn.Text = reversePlayback and "REVERSE ON" or "REVERSE OFF"
UI.snapBtn.Text = "SNAP " .. tostring(snapFPS)
UI.modeBtn.Text = "MODE: " .. string.upper(cameraMode)
UI.pathToggleBtn.Text = "CAMERA PATH: OFF"
UI.orbitToggleBtn.Text = "ORBIT: OFF"
UI.lookAtToggleBtn.Text = "LOOK AT TARGET: OFF"
updateShotControls(); updateBookmarkControls(); updateGuideVisibility()
refreshKeyframeList(); refreshTimelineMarkers(); refreshSelectedPanel(); refreshRuler(); updateTimeDisplays()
relayout()
openEditor()

print("[FramePlay] Upgraded editor started. /replay hides or shows the interface.")
