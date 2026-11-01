--[[
	CAMERA KEYFRAME EDITOR
	-----------------------------------------------------------------
	Single-LocalScript cinematic camera keyframe editor.
	PLACEMENT: StarterPlayer > StarterPlayerScripts

	Desktop (editor open, not playing):
		W/A/S/D move, E/Q up/down, Right Mouse hold+drag to look,
		Shift = speed boost, Mouse Wheel = adjust move speed,
		Space = play/pause, Delete = remove selected keyframe,
		Ctrl+D = duplicate selected keyframe, Esc = stop playback.

	Mobile (shown automatically on touch devices):
		Left thumbstick = move, Up/Down buttons = move up/down,
		Drag empty viewport = look around,
		Two-finger tap = stop UI-free playback and restore GUIs.
-----------------------------------------------------------------]]

----------------------------------------------------------------------
-- SERVICES
----------------------------------------------------------------------
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local isTouchDevice = UserInputService.TouchEnabled

-- Saves and temporarily hides every PlayerGui LayerCollector plus Roblox CoreGui
-- (including the two core topbar icons). Restored when playback ends or stops.
local savedPlayerGuiStates = nil
local savedCoreGuiStates = {}
local savedTopbarEnabled = true
local savedDevConsoleVisible = false
local hasSavedDevConsoleState = false
local playbackGuiAddedConnection = nil
local coreGuiReassertConnection = nil

local function hideAllPlaybackGuis()
	if savedPlayerGuiStates then return end

	savedPlayerGuiStates = {}
	savedCoreGuiStates = {}

	local function hideLayerCollector(instance)
		if instance:IsA("LayerCollector") then
			savedPlayerGuiStates[instance] = instance.Enabled
			instance.Enabled = false
		end
	end

	for _, instance in ipairs(playerGui:GetDescendants()) do
		hideLayerCollector(instance)
	end

	-- Also hide ScreenGuis/BillboardGuis/SurfaceGuis created while playback is active.
	playbackGuiAddedConnection = playerGui.DescendantAdded:Connect(function(instance)
		if savedPlayerGuiStates and instance:IsA("LayerCollector") then
			if savedPlayerGuiStates[instance] == nil then
				savedPlayerGuiStates[instance] = instance.Enabled
				instance.Enabled = false
			end
		end
	end)

	local topbarOk, topbarValue = pcall(function()
		return StarterGui:GetCore("TopbarEnabled")
	end)
	savedTopbarEnabled = (topbarOk and type(topbarValue) == "boolean") and topbarValue or true

	local devConsoleOk, devConsoleValue = pcall(function()
		return StarterGui:GetCore("DevConsoleVisible")
	end)
	hasSavedDevConsoleState = devConsoleOk and type(devConsoleValue) == "boolean"
	if hasSavedDevConsoleState then
		savedDevConsoleVisible = devConsoleValue
		pcall(function() StarterGui:SetCore("DevConsoleVisible", false) end)
	end

	-- Preserve each CoreGui element's own state before hiding Roblox's topbar/menu icons.
	for _, coreGuiType in ipairs(Enum.CoreGuiType:GetEnumItems()) do
		if coreGuiType.Name ~= "All" then
			local ok, enabled = pcall(function()
				return StarterGui:GetCoreGuiEnabled(coreGuiType)
			end)
			if ok then
				savedCoreGuiStates[coreGuiType] = enabled
			end
			pcall(function() StarterGui:SetCoreGuiEnabled(coreGuiType, false) end)
		end
	end

	-- TopbarEnabled=false hides Roblox's native topbar icons (the Roblox menu
	-- button and the hamburger/menu icon) along with chat, backpack, player list.
	pcall(function() StarterGui:SetCore("TopbarEnabled", false) end)

	-- Some Roblox client versions can briefly re-show the native topbar icons
	-- after other systems touch CoreGui. Re-assert every half second while
	-- playback GUIs are hidden so the two core buttons stay reliably hidden.
	if coreGuiReassertConnection then
		coreGuiReassertConnection:Disconnect()
		coreGuiReassertConnection = nil
	end
	local reassertAccum = 0
	coreGuiReassertConnection = RunService.Heartbeat:Connect(function(dt)
		reassertAccum = reassertAccum + dt
		if reassertAccum < 0.5 then return end
		reassertAccum = 0
		pcall(function() StarterGui:SetCore("TopbarEnabled", false) end)
	end)
end

local function restoreAllPlaybackGuis()
	if not savedPlayerGuiStates then return end

	if playbackGuiAddedConnection then
		playbackGuiAddedConnection:Disconnect()
		playbackGuiAddedConnection = nil
	end
	if coreGuiReassertConnection then
		coreGuiReassertConnection:Disconnect()
		coreGuiReassertConnection = nil
	end

	for instance, wasEnabled in pairs(savedPlayerGuiStates) do
		if instance and instance.Parent then
			pcall(function() instance.Enabled = wasEnabled end)
		end
	end

	for coreGuiType, wasEnabled in pairs(savedCoreGuiStates) do
		pcall(function() StarterGui:SetCoreGuiEnabled(coreGuiType, wasEnabled) end)
	end

	pcall(function() StarterGui:SetCore("TopbarEnabled", savedTopbarEnabled) end)
	if hasSavedDevConsoleState then
		pcall(function() StarterGui:SetCore("DevConsoleVisible", savedDevConsoleVisible) end)
	end

	savedPlayerGuiStates = nil
	savedCoreGuiStates = {}
	hasSavedDevConsoleState = false
end

----------------------------------------------------------------------
-- COLOR / STYLE PALETTE  (minimal, flat, CapCut-style with soft semantic accents)
----------------------------------------------------------------------
local COLORS = {
	background = Color3.fromRGB(17, 17, 19),
	panel = Color3.fromRGB(23, 23, 26),
	panelAlt = Color3.fromRGB(29, 29, 33),
	toolbar = Color3.fromRGB(20, 20, 23),
	border = Color3.fromRGB(42, 42, 48),
	divider = Color3.fromRGB(34, 34, 39),

	accent = Color3.fromRGB(92, 132, 250),       -- primary / neutral actions
	accentDim = Color3.fromRGB(52, 70, 120),

	success = Color3.fromRGB(96, 200, 150),      -- confirm / play / apply
	successDim = Color3.fromRGB(32, 58, 48),

	danger = Color3.fromRGB(232, 98, 98),        -- close / stop / delete
	dangerDim = Color3.fromRGB(62, 36, 38),

	warning = Color3.fromRGB(232, 178, 92),      -- pause / countdown / caution
	warningDim = Color3.fromRGB(58, 46, 26),

	text = Color3.fromRGB(236, 236, 241),
	muted = Color3.fromRGB(140, 140, 150),

	inputBg = Color3.fromRGB(15, 15, 18),
	buttonBg = Color3.fromRGB(36, 36, 41),
	markerColor = Color3.fromRGB(92, 132, 250),
	markerSelected = Color3.fromRGB(232, 178, 92),
	playhead = Color3.fromRGB(232, 98, 98),
	graphLine = Color3.fromRGB(96, 200, 150),
	graphAxis = Color3.fromRGB(50, 50, 56),
}

----------------------------------------------------------------------
-- SMALL GUI HELPER FUNCTIONS
----------------------------------------------------------------------
local function addCorner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

local function addStroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color or COLORS.border
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function addPadding(parent, l, t, r, b)
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, l or 6)
	p.PaddingTop = UDim.new(0, t or 6)
	p.PaddingRight = UDim.new(0, r or 6)
	p.PaddingBottom = UDim.new(0, b or 6)
	p.Parent = parent
	return p
end

local function makeFrame(parent, size, position, bgColor)
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = position or UDim2.new(0, 0, 0, 0)
	f.BackgroundColor3 = bgColor or COLORS.panel
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function makeLabel(parent, text, size, position, textSize, alignment)
	local lbl = Instance.new("TextLabel")
	lbl.Size = size
	lbl.Position = position or UDim2.new(0, 0, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = COLORS.text
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = textSize or 14
	if isTouchDevice then
		lbl.TextSize = math.max(9, math.floor(lbl.TextSize * 0.88))
	end
	lbl.Text = text
	lbl.TextXAlignment = alignment or Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.Parent = parent
	return lbl
end

local function makeButton(parent, text, size, position, accentColor)
	local btn = Instance.new("TextButton")
	btn.Size = size
	btn.Position = position or UDim2.new(0, 0, 0, 0)
	btn.BackgroundColor3 = accentColor or COLORS.buttonBg
	btn.TextColor3 = COLORS.text
	btn.Font = Enum.Font.GothamMedium
	btn.TextSize = isTouchDevice and 11 or 14
	btn.Text = text
	btn.AutoButtonColor = true
	btn.Parent = parent
	addCorner(btn, 7)
	return btn
end

local function makeTextBox(parent, placeholder, size, position)
	local tb = Instance.new("TextBox")
	tb.Size = size
	tb.Position = position or UDim2.new(0, 0, 0, 0)
	tb.BackgroundColor3 = COLORS.inputBg
	tb.TextColor3 = COLORS.text
	tb.PlaceholderText = placeholder or ""
	tb.PlaceholderColor3 = COLORS.muted
	tb.Font = Enum.Font.Gotham
	tb.TextSize = isTouchDevice and 11 or 14
	tb.Text = ""
	tb.ClearTextOnFocus = false
	tb.Parent = parent
	addCorner(tb, 5)
	addStroke(tb, COLORS.border, 1)
	return tb
end

local function clamp(v, lo, hi)
	if v < lo then return lo elseif v > hi then return hi else return v end
end

local function round(n, decimals)
	local mult = 10 ^ (decimals or 2)
	return math.floor(n * mult + 0.5) / mult
end

----------------------------------------------------------------------
-- CAMERA / ORIGINAL STATE CAPTURE
----------------------------------------------------------------------
local camera = Workspace.CurrentCamera

local originalCameraType = camera and camera.CameraType or Enum.CameraType.Custom
local originalFOV = camera and camera.FieldOfView or 70
local originalCameraSubject = camera and camera.CameraSubject or nil

-- Re-capture originals if CurrentCamera is ever replaced before we open editor,
-- so we always restore something sane.
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local newCam = Workspace.CurrentCamera
	if newCam and not editorOpenRef then
		camera = newCam
	end
end)

----------------------------------------------------------------------
-- EDITOR STATE
----------------------------------------------------------------------
editorOpenRef = false -- forward-declared global used by the signal above
local editorOpen = false
local editorMinimized = false

local keyframes = {} -- array of { cframe = CFrame, fov = number, time = number }
local selectedKeyframe = nil -- reference into `keyframes`

local isPlaying = false
local isPaused = false
local currentTime = 0
local duration = 10
local playbackSpeed = 1
local loopPlayback = false

local countdownSeconds = 3
local countdownActive = false
local cancelCountdown = nil -- assigned once the UI exists

-- Free-camera settings (adjustable from the Settings panel)
local camMoveSpeed = 40
local camSensitivity = 0.2
local defaultFOV = 70
local currentFOV = defaultFOV

-- Free-camera runtime state
local freeCamCFrame = camera and camera.CFrame or CFrame.new()
local moveState = { forward = false, backward = false, left = false, right = false, up = false, down = false }
local shiftHeld = false
local ctrlHeld = false
local rightMouseDown = false

-- Touch look / joystick runtime state
local touchLookActive = false
local touchLookId = nil
local lastTouchPos = nil
local joystickActive = false
local joystickId = nil
local joystickDir = Vector3.new(0, 0, 0) -- x = strafe, z = forward (y unused here)

local keyframeIdCounter = 0

----------------------------------------------------------------------
-- EASING FUNCTIONS  (expanded curve library, Robert Penner-style)
----------------------------------------------------------------------
local function bounceOutRaw(t)
	local n1, d1 = 7.5625, 2.75
	if t < 1 / d1 then
		return n1 * t * t
	elseif t < 2 / d1 then
		t = t - 1.5 / d1
		return n1 * t * t + 0.75
	elseif t < 2.5 / d1 then
		t = t - 2.25 / d1
		return n1 * t * t + 0.9375
	else
		t = t - 2.625 / d1
		return n1 * t * t + 0.984375
	end
end

local function easeValue(t, mode)
	t = clamp(t, 0, 1)
	local pi = math.pi
	if mode == "Linear" then
		return t
	elseif mode == "Smooth" then
		return t * t * (3 - 2 * t)
	elseif mode == "SineIn" then
		return 1 - math.cos((t * pi) / 2)
	elseif mode == "SineOut" then
		return math.sin((t * pi) / 2)
	elseif mode == "SineInOut" then
		return -(math.cos(pi * t) - 1) / 2
	elseif mode == "QuadIn" or mode == "EaseIn" then
		return t * t
	elseif mode == "QuadOut" or mode == "EaseOut" then
		return 1 - (1 - t) * (1 - t)
	elseif mode == "QuadInOut" or mode == "EaseInOut" then
		if t < 0.5 then return 2 * t * t end
		local f = -2 * t + 2
		return 1 - (f * f) / 2
	elseif mode == "CubicIn" then
		return t * t * t
	elseif mode == "CubicOut" then
		local f = 1 - t
		return 1 - f * f * f
	elseif mode == "CubicInOut" then
		if t < 0.5 then return 4 * t * t * t end
		local f = -2 * t + 2
		return 1 - (f * f * f) / 2
	elseif mode == "QuartIn" then
		return t * t * t * t
	elseif mode == "QuartOut" then
		local f = 1 - t
		return 1 - f * f * f * f
	elseif mode == "QuartInOut" then
		if t < 0.5 then return 8 * t * t * t * t end
		local f = -2 * t + 2
		return 1 - (f * f * f * f) / 2
	elseif mode == "ExpoIn" then
		return (t <= 0) and 0 or (2 ^ (10 * t - 10))
	elseif mode == "ExpoOut" then
		return (t >= 1) and 1 or (1 - 2 ^ (-10 * t))
	elseif mode == "ExpoInOut" then
		if t <= 0 then return 0 end
		if t >= 1 then return 1 end
		if t < 0.5 then return (2 ^ (20 * t - 10)) / 2 end
		return (2 - 2 ^ (-20 * t + 10)) / 2
	elseif mode == "CircIn" then
		return 1 - math.sqrt(1 - t * t)
	elseif mode == "CircOut" then
		return math.sqrt(1 - (t - 1) * (t - 1))
	elseif mode == "CircInOut" then
		if t < 0.5 then return (1 - math.sqrt(1 - (2 * t) * (2 * t))) / 2 end
		local f = -2 * t + 2
		return (math.sqrt(1 - f * f) + 1) / 2
	elseif mode == "BackIn" then
		local c1 = 1.70158
		local c3 = c1 + 1
		return c3 * t * t * t - c1 * t * t
	elseif mode == "BackOut" then
		local c1 = 1.70158
		local c3 = c1 + 1
		local f = t - 1
		return 1 + c3 * f * f * f + c1 * f * f
	elseif mode == "BackInOut" then
		local c1 = 1.70158
		local c2 = c1 * 1.525
		if t < 0.5 then
			return ((2 * t) * (2 * t) * ((c2 + 1) * 2 * t - c2)) / 2
		end
		local f = 2 * t - 2
		return (f * f * ((c2 + 1) * f + c2) + 2) / 2
	elseif mode == "ElasticIn" then
		if t <= 0 then return 0 end
		if t >= 1 then return 1 end
		local c4 = (2 * pi) / 3
		return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * c4)
	elseif mode == "ElasticOut" then
		if t <= 0 then return 0 end
		if t >= 1 then return 1 end
		local c4 = (2 * pi) / 3
		return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
	elseif mode == "BounceIn" then
		return 1 - bounceOutRaw(1 - t)
	elseif mode == "BounceOut" then
		return bounceOutRaw(t)
	end
	return t
end

-- Modes offered in the UI cycle button and the easing picker list.
-- ("EaseIn"/"EaseOut"/"EaseInOut" remain resolvable above for older exported JSON.)
local EASING_MODES = {
	"Linear", "Smooth",
	"SineIn", "SineOut", "SineInOut",
	"QuadIn", "QuadOut", "QuadInOut",
	"CubicIn", "CubicOut", "CubicInOut",
	"QuartIn", "QuartOut", "QuartInOut",
	"ExpoIn", "ExpoOut", "ExpoInOut",
	"CircIn", "CircOut", "CircInOut",
	"BackIn", "BackOut", "BackInOut",
	"ElasticIn", "ElasticOut",
	"BounceIn", "BounceOut",
}
local easingModeIndex = 1
local easingMode = EASING_MODES[easingModeIndex]

----------------------------------------------------------------------
-- KEYFRAME SYSTEM
----------------------------------------------------------------------
local TIME_EPSILON = 0.05 -- keyframes closer together than this are treated as "the same timestamp"

local function sortKeyframes()
	table.sort(keyframes, function(a, b)
		return a.time < b.time
	end)
end

-- Finds an existing keyframe within TIME_EPSILON of `t`, excluding `ignore` (used while dragging).
local function findKeyframeNear(t, ignore)
	for _, kf in ipairs(keyframes) do
		if kf ~= ignore and math.abs(kf.time - t) <= TIME_EPSILON then
			return kf
		end
	end
	return nil
end

-- Closest keyframe to a timestamp, used when a Remove action is pressed with nothing selected.
local function nearestKeyframeToTime(t)
	local best, bestDist = nil, math.huge
	for _, kf in ipairs(keyframes) do
		local d = math.abs(kf.time - t)
		if d < bestDist then
			best, bestDist = kf, d
		end
	end
	return best
end

-- Forward declarations for UI refresh functions (defined later, used by keyframe functions).
local refreshKeyframeList
local refreshTimelineMarkers
local refreshSelectedPanel
local updatePlayheadVisual
local updateTimeDisplays
local seekTo
local refreshRuler
local resetJoystick
local refreshCurveGraph

local function selectKeyframe(kf)
	selectedKeyframe = kf
	if refreshKeyframeList then refreshKeyframeList() end
	if refreshTimelineMarkers then refreshTimelineMarkers() end
	if refreshSelectedPanel then refreshSelectedPanel() end
end

-- Adds a keyframe at time `t` using the given CFrame and FOV. If a keyframe already
-- exists at (roughly) that timestamp, it is updated/replaced instead of duplicated.
local function addKeyframe(t, cf, fov)
	t = clamp(t, 0, duration)
	local existing = findKeyframeNear(t)
	if existing then
		existing.cframe = cf
		existing.fov = fov
		existing.time = t
		selectKeyframe(existing)
	else
		keyframeIdCounter = keyframeIdCounter + 1
		local kf = { id = keyframeIdCounter, cframe = cf, fov = fov, time = t }
		table.insert(keyframes, kf)
		sortKeyframes()
		selectKeyframe(kf)
	end
	refreshKeyframeList()
	refreshTimelineMarkers()
end

local function removeKeyframe(kf)
	if not kf then return end
	for i, existing in ipairs(keyframes) do
		if existing == kf then
			table.remove(keyframes, i)
			break
		end
	end
	if selectedKeyframe == kf then
		selectedKeyframe = nil
	end
	refreshKeyframeList()
	refreshTimelineMarkers()
	refreshSelectedPanel()
end

local function deleteSelectedKeyframe()
	if not selectedKeyframe then return end
	removeKeyframe(selectedKeyframe)
end

-- Used by the toolbar's quick Remove button: deletes the selection, or
-- falls back to the keyframe nearest the playhead if nothing is selected.
local function quickRemoveKeyframe()
	if selectedKeyframe then
		removeKeyframe(selectedKeyframe)
	else
		removeKeyframe(nearestKeyframeToTime(currentTime))
	end
end

local function duplicateKeyframe()
	if not selectedKeyframe then return end
	local src = selectedKeyframe
	local newTime = src.time + math.max(TIME_EPSILON * 2, duration * 0.02)
	newTime = clamp(newTime, 0, duration)
	-- Nudge forward until we find a free timestamp (bounded loop to avoid infinite spin).
	local guard = 0
	while findKeyframeNear(newTime) and guard < 200 do
		newTime = clamp(newTime + TIME_EPSILON * 2, 0, duration)
		guard = guard + 1
	end
	keyframeIdCounter = keyframeIdCounter + 1
	local kf = { id = keyframeIdCounter, cframe = src.cframe, fov = src.fov, time = newTime }
	table.insert(keyframes, kf)
	sortKeyframes()
	selectKeyframe(kf)
	refreshKeyframeList()
	refreshTimelineMarkers()
end

local function clearAllKeyframes()
	keyframes = {}
	selectedKeyframe = nil
	refreshKeyframeList()
	refreshTimelineMarkers()
	refreshSelectedPanel()
end

-- Moves a keyframe to a new timestamp, resolving collisions by overwriting
-- whatever keyframe currently sits at that timestamp (matching the "update or
-- replace the existing keyframe when appropriate" requirement).
local function moveKeyframeTiming(kf, newTime)
	newTime = clamp(newTime, 0, duration)
	local collision = findKeyframeNear(newTime, kf)
	if collision then
		for i, other in ipairs(keyframes) do
			if other == collision then
				table.remove(keyframes, i)
				break
			end
		end
	end
	kf.time = newTime
	sortKeyframes()
	refreshKeyframeList()
	refreshTimelineMarkers()
end

-- Evaluates camera CFrame + FOV at time `t` by interpolating between the
-- bounding keyframes using the current easing mode. Returns nil, nil if
-- there are no keyframes at all.
local function getCameraStateAtTime(t)
	local count = #keyframes
	if count == 0 then
		return nil, nil
	end
	if count == 1 then
		return keyframes[1].cframe, keyframes[1].fov
	end
	if t <= keyframes[1].time then
		return keyframes[1].cframe, keyframes[1].fov
	end
	if t >= keyframes[count].time then
		return keyframes[count].cframe, keyframes[count].fov
	end
	for i = 1, count - 1 do
		local a = keyframes[i]
		local b = keyframes[i + 1]
		if t >= a.time and t <= b.time then
			local span = b.time - a.time
			local alpha = 0
			if span > 0 then
				alpha = (t - a.time) / span
			end
			alpha = easeValue(alpha, easingMode)
			local cf = a.cframe:Lerp(b.cframe, alpha)
			local fov = a.fov + (b.fov - a.fov) * alpha
			return cf, fov
		end
	end
	-- Fallback (shouldn't be reached given the bounds checks above).
	return keyframes[count].cframe, keyframes[count].fov
end

----------------------------------------------------------------------
-- GUI CONSTRUCTION
----------------------------------------------------------------------
local function buildUI()

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CameraKeyframeEditorGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 1000
screenGui.Parent = playerGui

-- Root frame that holds the whole editor (hidden when the editor is closed).
local rootFrame = Instance.new("Frame")
rootFrame.Name = "Root"
rootFrame.Size = UDim2.new(1, 0, 1, 0)
rootFrame.BackgroundTransparency = 1
rootFrame.Visible = false
rootFrame.Parent = screenGui

-- A full-screen, low-ZIndex frame used to catch touch-drag camera look input
-- in the empty viewport area (i.e. wherever no panel/button is covering it).
local touchLookCatcher = Instance.new("TextButton")
touchLookCatcher.Name = "TouchLookCatcher"
touchLookCatcher.Size = UDim2.new(1, 0, 1, 0)
touchLookCatcher.BackgroundTransparency = 1
touchLookCatcher.Text = ""
touchLookCatcher.AutoButtonColor = false
touchLookCatcher.ZIndex = 1
touchLookCatcher.Parent = rootFrame

----------------------------------------------------------------------
-- TOP TOOLBAR
----------------------------------------------------------------------
local toolbarHeight = isTouchDevice and 36 or 48
local toolbar = makeFrame(rootFrame, UDim2.new(1, 0, 0, toolbarHeight), UDim2.new(0, 0, 0, 0), COLORS.toolbar)
toolbar.ZIndex = 5
toolbar.Active = true
addStroke(toolbar, COLORS.border, 1)

local titleWidth = isTouchDevice and 104 or 180
local titleLabel = makeLabel(toolbar, "CAMERA EDITOR", UDim2.new(0, titleWidth, 1, 0), UDim2.new(0, isTouchDevice and 8 or 14, 0, 0), isTouchDevice and 12 or 16)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.ZIndex = 5

local toolbarButtons = Instance.new("ScrollingFrame")
toolbarButtons.Size = UDim2.new(1, -(titleWidth + (isTouchDevice and 12 or 20)), 1, 0)
toolbarButtons.Position = UDim2.new(0, titleWidth + (isTouchDevice and 12 or 20), 0, 0)
toolbarButtons.BackgroundTransparency = 1
toolbarButtons.BorderSizePixel = 0
toolbarButtons.ScrollBarThickness = isTouchDevice and 2 or 0
toolbarButtons.ScrollingDirection = Enum.ScrollingDirection.X
toolbarButtons.AutomaticCanvasSize = Enum.AutomaticSize.X
toolbarButtons.CanvasSize = UDim2.new(0, 0, 0, 0)
toolbarButtons.ClipsDescendants = true
toolbarButtons.ZIndex = 5
toolbarButtons.Parent = toolbar

local tbLayout = Instance.new("UIListLayout")
tbLayout.FillDirection = Enum.FillDirection.Horizontal
tbLayout.VerticalAlignment = Enum.VerticalAlignment.Center
tbLayout.Padding = UDim.new(0, isTouchDevice and 3 or 6)
tbLayout.Parent = toolbarButtons

local function toolbarBtn(text, width, color)
	local mobileWidths = {
		Play = 42, Pause = 42, Stop = 42,
		["+ Key"] = 44, ["- Key"] = 44, Settings = 52, ["?"] = 25, ["_"] = 25, X = 25,
	}
	local buttonWidth = isTouchDevice and (mobileWidths[text] or math.floor((width or 70) * 0.7)) or (width or 70)
	local buttonHeight = isTouchDevice and 27 or 32
	local b = makeButton(toolbarButtons, text, UDim2.new(0, buttonWidth, 0, buttonHeight), nil, color)
	b.ZIndex = 5
	b.LayoutOrder = #toolbarButtons:GetChildren()
	return b
end

local playBtn = toolbarBtn("Play", 64, COLORS.success)
local pauseBtn = toolbarBtn("Pause", 64, COLORS.warning)
local stopBtn = toolbarBtn("Stop", 64, COLORS.danger)
local addKeyBtn = toolbarBtn(isTouchDevice and "+ Key" or "+ Keyframe", 96, COLORS.accent)
local removeKeyBtn = toolbarBtn(isTouchDevice and "- Key" or "- Keyframe", 96, COLORS.dangerDim)
local settingsBtn = toolbarBtn("Settings", 80)
local helpBtn = toolbarBtn("?", 30)
local minimizeBtn = toolbarBtn("_", 36)
local closeBtn = toolbarBtn("X", 36, COLORS.danger)

----------------------------------------------------------------------
-- LEFT PANEL (keyframe list + selected keyframe editor)
----------------------------------------------------------------------
local leftPanelWidth = isTouchDevice and 176 or 260
local timelineHeight = isTouchDevice and 108 or 150

local leftPanel = makeFrame(
	rootFrame,
	UDim2.new(0, leftPanelWidth, 1, -toolbarHeight - timelineHeight),
	UDim2.new(0, 0, 0, toolbarHeight),
	COLORS.panel
)
leftPanel.ZIndex = 4
leftPanel.Active = true
addStroke(leftPanel, COLORS.border, 1)
addPadding(leftPanel, isTouchDevice and 5 or 8, isTouchDevice and 5 or 8, isTouchDevice and 5 or 8, isTouchDevice and 5 or 8)

local leftLayout = Instance.new("UIListLayout")
leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
leftLayout.Padding = UDim.new(0, isTouchDevice and 4 or 6)
leftLayout.Parent = leftPanel

local keyframeListLabel = makeLabel(leftPanel, "KEYFRAMES", UDim2.new(1, 0, 0, isTouchDevice and 15 or 18), nil, isTouchDevice and 11 or 13)
keyframeListLabel.Font = Enum.Font.GothamBold
keyframeListLabel.TextColor3 = COLORS.muted
keyframeListLabel.LayoutOrder = 1
keyframeListLabel.ZIndex = 4

local keyframeListFrame = Instance.new("ScrollingFrame")
keyframeListFrame.Size = UDim2.new(1, 0, 0, isTouchDevice and 88 or 140)
keyframeListFrame.BackgroundColor3 = COLORS.panelAlt
keyframeListFrame.BorderSizePixel = 0
keyframeListFrame.ScrollBarThickness = isTouchDevice and 3 or 6
keyframeListFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
keyframeListFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
keyframeListFrame.LayoutOrder = 2
keyframeListFrame.ZIndex = 4
keyframeListFrame.Parent = leftPanel
addCorner(keyframeListFrame, 7)

local keyframeListLayout = Instance.new("UIListLayout")
keyframeListLayout.SortOrder = Enum.SortOrder.LayoutOrder
keyframeListLayout.Padding = UDim.new(0, isTouchDevice and 2 or 3)
keyframeListLayout.Parent = keyframeListFrame
addPadding(keyframeListFrame, 4, 4, 4, 4)

local keyframeListButtons = {} -- kf -> button, so we can clean up / restyle

refreshKeyframeList = function()
	for _, child in ipairs(keyframeListFrame:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	keyframeListButtons = {}
	for index, kf in ipairs(keyframes) do
		local row = makeButton(
			keyframeListFrame,
			string.format("#%d   t = %.2fs", index, kf.time),
			UDim2.new(1, 0, 0, isTouchDevice and 22 or 26)
		)
		row.ZIndex = 4
		row.LayoutOrder = index
		row.TextXAlignment = Enum.TextXAlignment.Left
		addPadding(row, 8, 0, 8, 0)
		if kf == selectedKeyframe then
			row.BackgroundColor3 = COLORS.accentDim
		end
		row.Activated:Connect(function()
			selectKeyframe(kf)
			seekTo(kf.time)
		end)
		keyframeListButtons[kf] = row
	end
end

-- Selected keyframe info / editor section
local selectedLabel = makeLabel(leftPanel, "SELECTED KEYFRAME", UDim2.new(1, 0, 0, isTouchDevice and 15 or 18), nil, isTouchDevice and 10 or 13)
selectedLabel.Font = Enum.Font.GothamBold
selectedLabel.TextColor3 = COLORS.muted
selectedLabel.LayoutOrder = 3
selectedLabel.ZIndex = 4

local selectedInfoFrame = Instance.new("Frame")
selectedInfoFrame.Size = UDim2.new(1, 0, 1, isTouchDevice and -165 or -200)
selectedInfoFrame.BackgroundTransparency = 1
selectedInfoFrame.LayoutOrder = 4
selectedInfoFrame.ZIndex = 4
selectedInfoFrame.Parent = leftPanel

local infoLayout = Instance.new("UIListLayout")
infoLayout.SortOrder = Enum.SortOrder.LayoutOrder
infoLayout.Padding = UDim.new(0, isTouchDevice and 2 or 4)
infoLayout.Parent = selectedInfoFrame

local function labeledField(parent, labelText, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, isTouchDevice and 18 or 22)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.ZIndex = 4
	row.Parent = parent

	local labelWidth = isTouchDevice and 52 or 70
	local lbl = makeLabel(row, labelText, UDim2.new(0, labelWidth, 1, 0), nil, isTouchDevice and 10 or 12)
	lbl.TextColor3 = COLORS.muted
	lbl.ZIndex = 4

	local tb = makeTextBox(row, "0", UDim2.new(1, -(labelWidth + 4), 1, 0), UDim2.new(0, labelWidth + 4, 0, 0))
	tb.ZIndex = 4
	return tb
end

local posXBox = labeledField(selectedInfoFrame, "Pos X", 1)
local posYBox = labeledField(selectedInfoFrame, "Pos Y", 2)
local posZBox = labeledField(selectedInfoFrame, "Pos Z", 3)
local rotXBox = labeledField(selectedInfoFrame, "Rot X°", 4)
local rotYBox = labeledField(selectedInfoFrame, "Rot Y°", 5)
local rotZBox = labeledField(selectedInfoFrame, "Rot Z°", 6)
local fovBox = labeledField(selectedInfoFrame, "FOV", 7)
local timeBox = labeledField(selectedInfoFrame, "Time (s)", 8)

local selectedButtonsRow = isTouchDevice and Instance.new("ScrollingFrame") or Instance.new("Frame")
selectedButtonsRow.Size = UDim2.new(1, 0, 0, isTouchDevice and 24 or 30)
selectedButtonsRow.BackgroundTransparency = 1
selectedButtonsRow.BorderSizePixel = 0
if isTouchDevice then
	selectedButtonsRow.ScrollingDirection = Enum.ScrollingDirection.X
	selectedButtonsRow.AutomaticCanvasSize = Enum.AutomaticSize.X
	selectedButtonsRow.CanvasSize = UDim2.new(0, 0, 0, 0)
	selectedButtonsRow.ScrollBarThickness = 2
end
selectedButtonsRow.LayoutOrder = 9
selectedButtonsRow.ZIndex = 4
selectedButtonsRow.Parent = selectedInfoFrame

local sbLayout = Instance.new("UIListLayout")
sbLayout.FillDirection = Enum.FillDirection.Horizontal
sbLayout.Padding = UDim.new(0, isTouchDevice and 3 or 4)
sbLayout.Parent = selectedButtonsRow

local applyFieldsBtn = makeButton(selectedButtonsRow, "Apply", UDim2.new(0, isTouchDevice and 48 or 74, 1, 0), nil, COLORS.success)
applyFieldsBtn.ZIndex = 4
local snapToCameraBtn = makeButton(selectedButtonsRow, isTouchDevice and "Snap Cam" or "Snap to Cam", UDim2.new(0, isTouchDevice and 66 or 96, 1, 0), COLORS.accent)
snapToCameraBtn.ZIndex = 4
local duplicateBtn = makeButton(selectedButtonsRow, "Duplicate", UDim2.new(0, isTouchDevice and 58 or 86, 1, 0))
duplicateBtn.ZIndex = 4
local deleteBtn = makeButton(selectedButtonsRow, "Delete", UDim2.new(0, isTouchDevice and 46 or 70, 1, 0), nil, COLORS.danger)
deleteBtn.ZIndex = 4

local clearAllBtn = makeButton(selectedInfoFrame, "Clear All Keyframes", UDim2.new(1, 0, 0, isTouchDevice and 22 or 26), nil, COLORS.dangerDim)
clearAllBtn.LayoutOrder = 10
clearAllBtn.ZIndex = 4

refreshSelectedPanel = function()
	if not selectedKeyframe then
		posXBox.Text, posYBox.Text, posZBox.Text = "", "", ""
		rotXBox.Text, rotYBox.Text, rotZBox.Text = "", "", ""
		fovBox.Text, timeBox.Text = "", ""
		return
	end
	local kf = selectedKeyframe
	local pos = kf.cframe.Position
	local rx, ry, rz = kf.cframe:ToOrientation()
	posXBox.Text = tostring(round(pos.X))
	posYBox.Text = tostring(round(pos.Y))
	posZBox.Text = tostring(round(pos.Z))
	rotXBox.Text = tostring(round(math.deg(rx)))
	rotYBox.Text = tostring(round(math.deg(ry)))
	rotZBox.Text = tostring(round(math.deg(rz)))
	fovBox.Text = tostring(round(kf.fov))
	timeBox.Text = tostring(round(kf.time))
end

----------------------------------------------------------------------
-- BOTTOM TIMELINE
----------------------------------------------------------------------
local timeline = makeFrame(rootFrame, UDim2.new(1, 0, 0, timelineHeight), UDim2.new(0, 0, 1, -timelineHeight), COLORS.toolbar)
timeline.ZIndex = 4
timeline.Active = true
addStroke(timeline, COLORS.border, 1)
addPadding(timeline, isTouchDevice and 6 or 10, isTouchDevice and 5 or 8, isTouchDevice and 6 or 10, isTouchDevice and 5 or 8)

-- Timeline control row (playback buttons + duration + speed + loop)
local timelineControls = isTouchDevice and Instance.new("ScrollingFrame") or Instance.new("Frame")
timelineControls.Size = UDim2.new(1, 0, 0, isTouchDevice and 24 or 28)
timelineControls.BackgroundTransparency = 1
timelineControls.BorderSizePixel = 0
if isTouchDevice then
	timelineControls.ScrollingDirection = Enum.ScrollingDirection.X
	timelineControls.AutomaticCanvasSize = Enum.AutomaticSize.X
	timelineControls.CanvasSize = UDim2.new(0, 0, 0, 0)
	timelineControls.ScrollBarThickness = 2
end
timelineControls.BackgroundTransparency = 1
timelineControls.ZIndex = 4
timelineControls.Parent = timeline

local tcLayout = Instance.new("UIListLayout")
tcLayout.FillDirection = Enum.FillDirection.Horizontal
tcLayout.VerticalAlignment = Enum.VerticalAlignment.Center
tcLayout.Padding = UDim.new(0, isTouchDevice and 3 or 6)
tcLayout.Parent = timelineControls

local prevKeyBtn = makeButton(timelineControls, "|<", UDim2.new(0, isTouchDevice and 28 or 36, 1, 0))
prevKeyBtn.ZIndex = 4
local restartBtn = makeButton(timelineControls, "Restart", UDim2.new(0, isTouchDevice and 48 or 64, 1, 0))
restartBtn.ZIndex = 4
local nextKeyBtn = makeButton(timelineControls, ">|", UDim2.new(0, isTouchDevice and 28 or 36, 1, 0))
nextKeyBtn.ZIndex = 4

local durationLabel = makeLabel(timelineControls, isTouchDevice and "Dur." or "Duration", UDim2.new(0, isTouchDevice and 32 or 56, 1, 0), nil, 12)
durationLabel.TextColor3 = COLORS.muted
durationLabel.ZIndex = 4
local durationBox = makeTextBox(timelineControls, "10", UDim2.new(0, isTouchDevice and 36 or 50, 1, 0))
durationBox.Text = tostring(duration)
durationBox.ZIndex = 4

local speedLabel = makeLabel(timelineControls, isTouchDevice and "Spd." or "Speed", UDim2.new(0, isTouchDevice and 30 or 44, 1, 0), nil, 12)
speedLabel.TextColor3 = COLORS.muted
speedLabel.ZIndex = 4
local speedBox = makeTextBox(timelineControls, "1", UDim2.new(0, isTouchDevice and 34 or 46, 1, 0))
speedBox.Text = tostring(playbackSpeed)
speedBox.ZIndex = 4

local loopBtn = makeButton(timelineControls, isTouchDevice and "Loop" or "Loop: Off", UDim2.new(0, isTouchDevice and 52 or 84, 1, 0))
loopBtn.ZIndex = 4

local easingBtn = makeButton(timelineControls, "Ease: " .. easingMode, UDim2.new(0, isTouchDevice and 100 or 136, 1, 0), nil, COLORS.accent)
easingBtn.ZIndex = 4

local timeDisplay = makeLabel(timelineControls, "0.00 / 10.00s", UDim2.new(0, isTouchDevice and 88 or 110, 1, 0), nil, isTouchDevice and 10 or 13, Enum.TextXAlignment.Right)
timeDisplay.ZIndex = 4

-- Timeline ruler + track
local trackContainer = Instance.new("Frame")
trackContainer.Size = UDim2.new(1, 0, 1, isTouchDevice and -28 or -34)
trackContainer.Position = UDim2.new(0, 0, 0, isTouchDevice and 28 or 34)
trackContainer.BackgroundColor3 = COLORS.panelAlt
trackContainer.BorderSizePixel = 0
trackContainer.ZIndex = 4
trackContainer.Active = true
trackContainer.Parent = timeline
addCorner(trackContainer, 7)
addStroke(trackContainer, COLORS.border, 1)

local rulerFrame = Instance.new("Frame")
rulerFrame.Size = UDim2.new(1, 0, 0, isTouchDevice and 14 or 18)
rulerFrame.BackgroundTransparency = 1
rulerFrame.ZIndex = 4
rulerFrame.Parent = trackContainer

local trackFrame = Instance.new("Frame")
trackFrame.Name = "Track"
trackFrame.Size = UDim2.new(1, -4, 1, isTouchDevice and -18 or -22)
trackFrame.Position = UDim2.new(0, 2, 0, isTouchDevice and 14 or 18)
trackFrame.BackgroundColor3 = COLORS.panel
trackFrame.BorderSizePixel = 0
trackFrame.ZIndex = 4
trackFrame.Active = true
trackFrame.Parent = trackContainer
addCorner(trackFrame, 5)

local playheadFrame = Instance.new("Frame")
playheadFrame.Name = "Playhead"
playheadFrame.Size = UDim2.new(0, 2, 1, 0)
playheadFrame.Position = UDim2.new(0, 0, 0, 0)
playheadFrame.BackgroundColor3 = COLORS.playhead
playheadFrame.BorderSizePixel = 0
playheadFrame.ZIndex = 6
playheadFrame.Parent = trackFrame

local function timeToX(t)
	local w = trackFrame.AbsoluteSize.X
	if w <= 0 then w = 1 end
	return (t / math.max(duration, 0.001)) * w
end

local function xToTime(x)
	local w = trackFrame.AbsoluteSize.X
	if w <= 0 then w = 1 end
	return clamp((x / w) * duration, 0, duration)
end

updatePlayheadVisual = function()
	playheadFrame.Position = UDim2.new(0, timeToX(currentTime) - 1, 0, 0)
end

updateTimeDisplays = function()
	timeDisplay.Text = string.format("%.2f / %.2fs", currentTime, duration)
end

local rulerMarks = {}
refreshRuler = function()
	for _, m in ipairs(rulerMarks) do
		m:Destroy()
	end
	rulerMarks = {}
	local step = math.max(1, math.floor(duration / 10))
	local t = 0
	while t <= duration do
		local mark = makeLabel(rulerFrame, string.format("%ds", t), UDim2.new(0, 36, 1, 0), UDim2.new(0, timeToX(t) - 2, 0, 0), 11)
		mark.TextColor3 = COLORS.muted
		mark.ZIndex = 4
		table.insert(rulerMarks, mark)
		t = t + step
	end
end

local keyframeMarkers = {}
refreshTimelineMarkers = function()
	for _, m in ipairs(keyframeMarkers) do
		m:Destroy()
	end
	keyframeMarkers = {}
	for _, kf in ipairs(keyframes) do
		local marker = Instance.new("TextButton")
		marker.Size = UDim2.new(0, 10, 0, 10)
		marker.AnchorPoint = Vector2.new(0.5, 0.5)
		marker.Position = UDim2.new(0, timeToX(kf.time), 0.5, 0)
		marker.BackgroundColor3 = (kf == selectedKeyframe) and COLORS.markerSelected or COLORS.markerColor
		marker.Text = ""
		marker.AutoButtonColor = false
		marker.ZIndex = 7
		marker.Parent = trackFrame
		addCorner(marker, 5)
		addStroke(marker, COLORS.background, 1)

		marker.Activated:Connect(function()
			selectKeyframe(kf)
			seekTo(kf.time)
		end)

		-- Drag-to-retime support (desktop mouse + touch).
		marker.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				selectKeyframe(kf)
				local dragging = true
				local moveConn, endConn
				moveConn = UserInputService.InputChanged:Connect(function(moveInput)
					if not dragging then return end
					if moveInput.UserInputType == Enum.UserInputType.MouseMovement or moveInput.UserInputType == Enum.UserInputType.Touch then
						local localX = moveInput.Position.X - trackFrame.AbsolutePosition.X
						local newTime = xToTime(localX)
						moveKeyframeTiming(kf, newTime)
						seekTo(newTime)
					end
				end)
				endConn = UserInputService.InputEnded:Connect(function(endInput)
					if endInput.UserInputType == Enum.UserInputType.MouseButton1 or endInput.UserInputType == Enum.UserInputType.Touch then
						dragging = false
						if moveConn then moveConn:Disconnect() end
						if endConn then endConn:Disconnect() end
					end
				end)
			end
		end)

		keyframeMarkers[#keyframeMarkers + 1] = marker
	end
end

-- Clicking/dragging on the empty track area scrubs the playhead.
local scrubbing = false
trackFrame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		scrubbing = true
		local localX = input.Position.X - trackFrame.AbsolutePosition.X
		seekTo(xToTime(localX))
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if scrubbing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local localX = input.Position.X - trackFrame.AbsolutePosition.X
		seekTo(xToTime(localX))
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		scrubbing = false
	end
end)

----------------------------------------------------------------------
-- SETTINGS PANEL (overlay, toggled via the Settings button)
----------------------------------------------------------------------
local settingsBackdrop = Instance.new("Frame")
settingsBackdrop.Size = UDim2.new(1, 0, 1, 0)
settingsBackdrop.BackgroundColor3 = Color3.new(0, 0, 0)
settingsBackdrop.BackgroundTransparency = 0.5
settingsBackdrop.Visible = false
settingsBackdrop.ZIndex = 10
settingsBackdrop.Active = true
settingsBackdrop.Parent = rootFrame

local settingsPanel = makeFrame(
	settingsBackdrop,
	isTouchDevice and UDim2.new(0.92, 0, 0.84, 0) or UDim2.new(0, 380, 0, 560),
	isTouchDevice and UDim2.new(0.04, 0, 0.08, 0) or UDim2.new(0.5, -190, 0.5, -280),
	COLORS.panel
)
settingsPanel.ZIndex = 11
settingsPanel.Active = true
addCorner(settingsPanel, 12)
addStroke(settingsPanel, COLORS.border, 1)
addPadding(settingsPanel, isTouchDevice and 9 or 14, isTouchDevice and 9 or 14, isTouchDevice and 9 or 14, isTouchDevice and 9 or 14)

local settingsTitle = makeLabel(settingsPanel, "SETTINGS", UDim2.new(1, -30, 0, 22), nil, 16)
settingsTitle.Font = Enum.Font.GothamBold
settingsTitle.ZIndex = 11

local settingsCloseBtn = makeButton(settingsPanel, "X", UDim2.new(0, 26, 0, 22), UDim2.new(1, -26, 0, 0), COLORS.danger)
settingsCloseBtn.ZIndex = 11

-- Always scrollable: the panel now holds enough rows (curve preview, countdown,
-- data import/export) that a fixed, non-scrolling Frame could clip content.
local settingsList = Instance.new("ScrollingFrame")
settingsList.Size = UDim2.new(1, 0, 1, -34)
settingsList.Position = UDim2.new(0, 0, 0, 34)
settingsList.BackgroundTransparency = 1
settingsList.BorderSizePixel = 0
settingsList.ScrollingDirection = Enum.ScrollingDirection.Y
settingsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
settingsList.CanvasSize = UDim2.new(0, 0, 0, 0)
settingsList.ScrollBarThickness = isTouchDevice and 3 or 5
settingsList.ZIndex = 11
settingsList.Parent = settingsPanel

local settingsLayout = Instance.new("UIListLayout")
settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
settingsLayout.Padding = UDim.new(0, isTouchDevice and 5 or 8)
settingsLayout.Parent = settingsList

local settingsLabelWidth = isTouchDevice and 116 or 160

local function settingsRow(labelText, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, isTouchDevice and 21 or 24)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.ZIndex = 11
	row.Parent = settingsList
	local lbl = makeLabel(row, labelText, UDim2.new(0, settingsLabelWidth, 1, 0), nil, isTouchDevice and 11 or 13)
	lbl.ZIndex = 11
	local tb = makeTextBox(row, "", UDim2.new(1, -(settingsLabelWidth + 4), 1, 0), UDim2.new(0, settingsLabelWidth + 4, 0, 0))
	tb.ZIndex = 11
	return tb
end

local camSpeedBox = settingsRow("Camera Move Speed", 1)
camSpeedBox.Text = tostring(camMoveSpeed)
local sensitivityBox = settingsRow("Mouse Sensitivity", 2)
sensitivityBox.Text = tostring(camSensitivity)
local defaultFovBox = settingsRow("Default FOV", 3)
defaultFovBox.Text = tostring(defaultFOV)
local settingsSpeedBox = settingsRow("Playback Speed", 4)
settingsSpeedBox.Text = tostring(playbackSpeed)

-- Interpolation (easing) picker
local settingsEasingRow = Instance.new("Frame")
settingsEasingRow.Size = UDim2.new(1, 0, 0, 24)
settingsEasingRow.BackgroundTransparency = 1
settingsEasingRow.LayoutOrder = 5
settingsEasingRow.ZIndex = 11
settingsEasingRow.Parent = settingsList
local easingRowLabel = makeLabel(settingsEasingRow, "Motion Curve", UDim2.new(0, settingsLabelWidth, 1, 0), nil, isTouchDevice and 11 or 13)
easingRowLabel.ZIndex = 11
local settingsEasingBtn = makeButton(settingsEasingRow, easingMode, UDim2.new(1, -(settingsLabelWidth + 4), 1, 0), UDim2.new(0, settingsLabelWidth + 4, 0, 0), COLORS.accent)
settingsEasingBtn.ZIndex = 11

-- Curve preview (small graph showing the shape of the selected motion curve)
local curveCanvas = Instance.new("Frame")
curveCanvas.Size = UDim2.new(1, 0, 0, isTouchDevice and 56 or 70)
curveCanvas.BackgroundColor3 = COLORS.inputBg
curveCanvas.BorderSizePixel = 0
curveCanvas.ClipsDescendants = true
curveCanvas.LayoutOrder = 6
curveCanvas.ZIndex = 11
curveCanvas.Parent = settingsList
addCorner(curveCanvas, 6)
addStroke(curveCanvas, COLORS.border, 1)

local curveBaseline = Instance.new("Frame")
curveBaseline.Size = UDim2.new(1, 0, 0, 1)
curveBaseline.Position = UDim2.new(0, 0, 1, -1)
curveBaseline.BackgroundColor3 = COLORS.graphAxis
curveBaseline.BorderSizePixel = 0
curveBaseline.ZIndex = 11
curveBaseline.Parent = curveCanvas

local function drawCurveInto(canvas, modeName)
	for _, child in ipairs(canvas:GetChildren()) do
		if child:IsA("Frame") and child.Name == "CurveSeg" then
			child:Destroy()
		end
	end
	local w, h = canvas.AbsoluteSize.X, canvas.AbsoluteSize.Y
	if w <= 1 or h <= 1 then w, h = 300, 70 end
	local samples = 32
	local prevPoint = nil
	for i = 0, samples do
		local t = i / samples
		local v = easeValue(t, modeName)
		local point = Vector2.new(t * w, h - (v * h))
		if prevPoint then
			local delta = point - prevPoint
			local length = math.max(delta.Magnitude, 1)
			local angle = math.deg(math.atan2(delta.Y, delta.X))
			local seg = Instance.new("Frame")
			seg.Name = "CurveSeg"
			seg.AnchorPoint = Vector2.new(0, 0.5)
			seg.Position = UDim2.new(0, prevPoint.X, 0, prevPoint.Y)
			seg.Size = UDim2.new(0, length, 0, 2)
			seg.Rotation = angle
			seg.BackgroundColor3 = COLORS.graphLine
			seg.BorderSizePixel = 0
			seg.ZIndex = 12
			seg.Parent = canvas
		end
		prevPoint = point
	end
end

refreshCurveGraph = function()
	drawCurveInto(curveCanvas, easingMode)
end

local curveDrawnOnce = false
curveCanvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if not curveDrawnOnce then
		curveDrawnOnce = true
		refreshCurveGraph()
	end
end)

-- Full picker list (overlay, toggled by settingsEasingBtn)
local easingDropdown = Instance.new("ScrollingFrame")
easingDropdown.Size = isTouchDevice and UDim2.new(1, -18, 0, 190) or UDim2.new(1, -28, 0, 220)
easingDropdown.Position = isTouchDevice and UDim2.new(0, 9, 0, 108) or UDim2.new(0, 14, 0, 118)
easingDropdown.BackgroundColor3 = COLORS.panelAlt
easingDropdown.BorderSizePixel = 0
easingDropdown.ScrollBarThickness = 4
easingDropdown.CanvasSize = UDim2.new(0, 0, 0, 0)
easingDropdown.AutomaticCanvasSize = Enum.AutomaticSize.Y
easingDropdown.Visible = false
easingDropdown.ZIndex = 20
easingDropdown.Active = true
easingDropdown.Parent = settingsPanel
addCorner(easingDropdown, 8)
addStroke(easingDropdown, COLORS.border, 1)
addPadding(easingDropdown, 5, 5, 5, 5)

local easingDropdownLayout = Instance.new("UIListLayout")
easingDropdownLayout.SortOrder = Enum.SortOrder.LayoutOrder
easingDropdownLayout.Padding = UDim.new(0, 3)
easingDropdownLayout.Parent = easingDropdown

local settingsLoopRow = Instance.new("Frame")
settingsLoopRow.Size = UDim2.new(1, 0, 0, 24)
settingsLoopRow.BackgroundTransparency = 1
settingsLoopRow.LayoutOrder = 7
settingsLoopRow.ZIndex = 11
settingsLoopRow.Parent = settingsList
local loopRowLabel = makeLabel(settingsLoopRow, "Loop Playback", UDim2.new(0, settingsLabelWidth, 1, 0), nil, isTouchDevice and 11 or 13)
loopRowLabel.ZIndex = 11
local settingsLoopBtn = makeButton(settingsLoopRow, "Off", UDim2.new(1, -(settingsLabelWidth + 4), 1, 0), UDim2.new(0, settingsLabelWidth + 4, 0, 0))
settingsLoopBtn.ZIndex = 11

local countdownRow = Instance.new("Frame")
countdownRow.Size = UDim2.new(1, 0, 0, 24)
countdownRow.BackgroundTransparency = 1
countdownRow.LayoutOrder = 8
countdownRow.ZIndex = 11
countdownRow.Parent = settingsList
local countdownRowLabel = makeLabel(countdownRow, "Countdown (s)", UDim2.new(0, settingsLabelWidth, 1, 0), nil, isTouchDevice and 11 or 13)
countdownRowLabel.ZIndex = 11
local countdownSecondsBox = makeTextBox(countdownRow, "3", UDim2.new(1, -(settingsLabelWidth + 4), 1, 0), UDim2.new(0, settingsLabelWidth + 4, 0, 0))
countdownSecondsBox.Text = tostring(countdownSeconds)
countdownSecondsBox.ZIndex = 11

local applySettingsBtn = makeButton(settingsList, "Apply Settings", UDim2.new(1, 0, 0, isTouchDevice and 25 or 28), nil, COLORS.success)
applySettingsBtn.LayoutOrder = 9
applySettingsBtn.ZIndex = 11

-- Data (export / import) section
local dataLabel = makeLabel(settingsList, "KEYFRAME DATA (JSON)", UDim2.new(1, 0, 0, 16), nil, 12)
dataLabel.Font = Enum.Font.GothamBold
dataLabel.TextColor3 = COLORS.muted
dataLabel.LayoutOrder = 10
dataLabel.ZIndex = 11

local exportBtn = makeButton(settingsList, "Export Keyframes", UDim2.new(1, 0, 0, 26), nil, COLORS.accent)
exportBtn.LayoutOrder = 11
exportBtn.ZIndex = 11

local jsonBox = Instance.new("TextBox")
jsonBox.Size = UDim2.new(1, 0, 0, isTouchDevice and 58 or 70)
jsonBox.BackgroundColor3 = COLORS.inputBg
jsonBox.TextColor3 = COLORS.text
jsonBox.Font = Enum.Font.Code
jsonBox.TextSize = isTouchDevice and 10 or 12
jsonBox.ClearTextOnFocus = false
jsonBox.MultiLine = true
jsonBox.TextWrapped = true
jsonBox.TextXAlignment = Enum.TextXAlignment.Left
jsonBox.TextYAlignment = Enum.TextYAlignment.Top
jsonBox.PlaceholderText = "Exported JSON appears here. Paste JSON here and press Import to load it."
jsonBox.PlaceholderColor3 = COLORS.muted
jsonBox.LayoutOrder = 12
jsonBox.ZIndex = 11
jsonBox.Parent = settingsList
addCorner(jsonBox, 5)
addStroke(jsonBox, COLORS.border, 1)

local importBtn = makeButton(settingsList, "Import Keyframes", UDim2.new(1, 0, 0, isTouchDevice and 23 or 26), nil, COLORS.accent)
importBtn.LayoutOrder = 13
importBtn.ZIndex = 11

local dataStatusLabel = makeLabel(settingsList, "", UDim2.new(1, 0, 0, 16), nil, 12)
dataStatusLabel.LayoutOrder = 14
dataStatusLabel.ZIndex = 11

-- Populate the easing picker now that drawCurveInto/EASING_MODES exist.
local easingDropdownButtons = {}
for _, modeName in ipairs(EASING_MODES) do
	local row = makeButton(easingDropdown, modeName, UDim2.new(1, 0, 0, isTouchDevice and 22 or 24))
	row.ZIndex = 21
	row.TextXAlignment = Enum.TextXAlignment.Left
	addPadding(row, 8, 0, 8, 0)
	easingDropdownButtons[modeName] = row
end

-- Selecting a curve from the picker list.
for modeName, row in pairs(easingDropdownButtons) do
	row.Activated:Connect(function()
		for i, m in ipairs(EASING_MODES) do
			if m == modeName then
				easingModeIndex = i
				easingMode = m
				break
			end
		end
		easingBtn.Text = "Ease: " .. easingMode
		settingsEasingBtn.Text = easingMode
		refreshCurveGraph()
		easingDropdown.Visible = false
	end)
end

settingsEasingBtn.Activated:Connect(function()
	easingDropdown.Visible = not easingDropdown.Visible
end)

----------------------------------------------------------------------
-- MOBILE TOUCH CONTROLS (joystick + up/down buttons)
----------------------------------------------------------------------
local mobileControls = Instance.new("Frame")
mobileControls.Size = UDim2.new(1, 0, 1, 0)
mobileControls.BackgroundTransparency = 1
mobileControls.Visible = isTouchDevice
mobileControls.ZIndex = 8
mobileControls.Parent = rootFrame

-- Joystick base
local joystickBase = Instance.new("Frame")
local joystickSize = 74
joystickBase.Size = UDim2.new(0, joystickSize, 0, joystickSize)
joystickBase.Position = UDim2.new(0, leftPanelWidth + 8, 1, -(timelineHeight + joystickSize + 10))
joystickBase.AnchorPoint = Vector2.new(0, 0)
joystickBase.BackgroundColor3 = COLORS.panelAlt
joystickBase.BackgroundTransparency = 0.3
joystickBase.ZIndex = 8
joystickBase.Active = true
joystickBase.Parent = mobileControls
addCorner(joystickBase, joystickSize / 2)
addStroke(joystickBase, COLORS.border, 1)

local joystickKnob = Instance.new("Frame")
joystickKnob.Size = UDim2.new(0, 30, 0, 30)
joystickKnob.AnchorPoint = Vector2.new(0.5, 0.5)
joystickKnob.Position = UDim2.new(0.5, 0, 0.5, 0)
joystickKnob.BackgroundColor3 = COLORS.accent
joystickKnob.ZIndex = 9
joystickKnob.Parent = joystickBase
addCorner(joystickKnob, 15)

resetJoystick = function()
	joystickActive = false
	joystickId = nil
	joystickDir = Vector3.new(0, 0, 0)
	joystickKnob.Position = UDim2.new(0.5, 0, 0.5, 0)
end

local updateJoystickFromPos

joystickBase.InputBegan:Connect(function(input)
	if not joystickActive and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1) then
		joystickActive = true
		joystickId = input
		updateJoystickFromPos(input.Position)
	end
end)

updateJoystickFromPos = function(screenPos)
	local center = joystickBase.AbsolutePosition + joystickBase.AbsoluteSize / 2
	local offset = Vector2.new(screenPos.X, screenPos.Y) - center
	local maxDist = joystickBase.AbsoluteSize.X / 2
	local dist = math.min(offset.Magnitude, maxDist)
	local dir = (offset.Magnitude > 0) and (offset.Unit * dist) or Vector2.new(0, 0)
	joystickKnob.Position = UDim2.new(0.5, dir.X, 0.5, dir.Y)
	-- Convert screen-space offset into movement axes: X = strafe, Y(screen) = forward/back.
	local nx = (maxDist > 0) and (dir.X / maxDist) or 0
	local ny = (maxDist > 0) and (dir.Y / maxDist) or 0
	joystickDir = Vector3.new(nx, 0, ny)
end

UserInputService.InputChanged:Connect(function(input)
	if not joystickActive or not joystickId then return end

	local joystickStartedWithTouch = joystickId.UserInputType == Enum.UserInputType.Touch
	local isJoystickMovement = joystickStartedWithTouch
		and input.UserInputType == Enum.UserInputType.Touch
		and input == joystickId
	local isMouseMovement = not joystickStartedWithTouch
		and input.UserInputType == Enum.UserInputType.MouseMovement

	if isJoystickMovement or isMouseMovement then
		updateJoystickFromPos(input.Position)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not joystickActive or not joystickId then return end

	local joystickStartedWithTouch = joystickId.UserInputType == Enum.UserInputType.Touch
	local isJoystickReleased = joystickStartedWithTouch
		and input == joystickId
	local isMouseReleased = not joystickStartedWithTouch
		and input.UserInputType == Enum.UserInputType.MouseButton1

	if isJoystickReleased or isMouseReleased then
		resetJoystick()
	end
end)

-- Up / Down buttons
local upBtn = Instance.new("TextButton")
upBtn.Size = UDim2.new(0, 36, 0, 36)
upBtn.Position = UDim2.new(1, -80, 1, -(timelineHeight + 46))
upBtn.BackgroundColor3 = COLORS.panelAlt
upBtn.BackgroundTransparency = 0.2
upBtn.Text = "UP"
upBtn.TextColor3 = COLORS.text
upBtn.Font = Enum.Font.GothamMedium
upBtn.TextSize = 10
upBtn.ZIndex = 8
upBtn.Parent = mobileControls
addCorner(upBtn, 28)
addStroke(upBtn, COLORS.border, 1)

local downBtn = Instance.new("TextButton")
downBtn.Size = UDim2.new(0, 36, 0, 36)
downBtn.Position = UDim2.new(1, -40, 1, -(timelineHeight + 46))
downBtn.BackgroundColor3 = COLORS.panelAlt
downBtn.BackgroundTransparency = 0.2
downBtn.Text = "DOWN"
downBtn.TextColor3 = COLORS.text
downBtn.Font = Enum.Font.GothamMedium
downBtn.TextSize = 9
downBtn.ZIndex = 8
downBtn.Parent = mobileControls
addCorner(downBtn, 28)
addStroke(downBtn, COLORS.border, 1)

local function bindHoldButton(button, onDown, onUp)
	local heldPointer = nil
	button.InputBegan:Connect(function(input)
		if not heldPointer and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1) then
			heldPointer = input
			onDown()
		end
	end)
	button.InputEnded:Connect(function(input)
		if heldPointer and (input == heldPointer or (heldPointer.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)) then
			heldPointer = nil
			onUp()
		end
	end)
end

bindHoldButton(upBtn, function() moveState.up = true end, function() moveState.up = false end)
bindHoldButton(downBtn, function() moveState.down = true end, function() moveState.down = false end)

-- Touch-drag look (rotate camera) using the full-screen catcher behind the panels.
touchLookCatcher.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch and editorOpen and not isPlaying and not touchLookActive then
		touchLookActive = true
		touchLookId = input
		lastTouchPos = input.Position
	end
end)

----------------------------------------------------------------------
-- MINIMIZED STATE (small floating bar) + CLOSED STATE (small reopen bubble)
----------------------------------------------------------------------
local minimizedBar = Instance.new("Frame")
minimizedBar.Size = UDim2.new(0, isTouchDevice and 180 or 220, 0, isTouchDevice and 30 or 36)
minimizedBar.Position = UDim2.new(0, 10, 0, 10)
minimizedBar.BackgroundColor3 = COLORS.toolbar
minimizedBar.Visible = false
minimizedBar.ZIndex = 5
minimizedBar.Active = true
minimizedBar.Parent = screenGui
addCorner(minimizedBar, 9)
addStroke(minimizedBar, COLORS.border, 1)

local miniAccent = makeFrame(minimizedBar, UDim2.new(0, 3, 1, -10), UDim2.new(0, 4, 0, 5), COLORS.accent)
miniAccent.ZIndex = 6
addCorner(miniAccent, 2)

local minimizedLabel = makeLabel(minimizedBar, "CAMERA EDITOR", UDim2.new(1, -82, 1, 0), UDim2.new(0, 12, 0, 0), isTouchDevice and 10 or 12)
minimizedLabel.ZIndex = 6
minimizedLabel.Active = true -- Drag the bar by holding its title area.

local restoreBtn = makeButton(minimizedBar, "OPEN", UDim2.new(0, 42, 0, 24), UDim2.new(1, -68, 0, 3), COLORS.success)
restoreBtn.TextSize = isTouchDevice and 9 or 10
restoreBtn.ZIndex = 6

local minimizedCloseBtn = makeButton(minimizedBar, "X", UDim2.new(0, 22, 0, 24), UDim2.new(1, -25, 0, 3), COLORS.danger)
minimizedCloseBtn.TextSize = 10
minimizedCloseBtn.ZIndex = 6

-- Drag only from the title area, so OPEN and X remain easy to tap.
local draggingMinimizedBar = false
local minimizedDragInput = nil
local minimizedDragStart = nil
local minimizedStartPosition = nil

minimizedLabel.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
		draggingMinimizedBar = true
		minimizedDragInput = input
		minimizedDragStart = input.Position
		minimizedStartPosition = minimizedBar.Position
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not draggingMinimizedBar or not minimizedDragInput then return end

	local isTouchDrag = minimizedDragInput.UserInputType == Enum.UserInputType.Touch
		and input.UserInputType == Enum.UserInputType.Touch
		and input == minimizedDragInput
	local isMouseDrag = minimizedDragInput.UserInputType == Enum.UserInputType.MouseButton1
		and input.UserInputType == Enum.UserInputType.MouseMovement

	if isTouchDrag or isMouseDrag then
		local delta = input.Position - minimizedDragStart
		local maxX = math.max(0, rootFrame.AbsoluteSize.X - minimizedBar.AbsoluteSize.X)
		local maxY = math.max(0, rootFrame.AbsoluteSize.Y - minimizedBar.AbsoluteSize.Y)
		local newX = clamp(minimizedStartPosition.X.Offset + delta.X, 0, maxX)
		local newY = clamp(minimizedStartPosition.Y.Offset + delta.Y, 0, maxY)
		minimizedBar.Position = UDim2.new(0, newX, 0, newY)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not draggingMinimizedBar or not minimizedDragInput then return end
	local endedTouch = minimizedDragInput.UserInputType == Enum.UserInputType.Touch and input == minimizedDragInput
	local endedMouse = minimizedDragInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1
	if endedTouch or endedMouse then
		draggingMinimizedBar = false
		minimizedDragInput = nil
		minimizedDragStart = nil
		minimizedStartPosition = nil
	end
end)

local reopenBubble = Instance.new("TextButton")
reopenBubble.Size = UDim2.new(0, isTouchDevice and 40 or 48, 0, isTouchDevice and 40 or 48)
reopenBubble.Position = UDim2.new(0, 10, 0, 10)
reopenBubble.BackgroundColor3 = COLORS.accent
reopenBubble.Text = "CAM"
reopenBubble.TextColor3 = COLORS.text
reopenBubble.Font = Enum.Font.GothamBold
reopenBubble.TextSize = isTouchDevice and 10 or 13
reopenBubble.Visible = false
reopenBubble.ZIndex = 5
reopenBubble.Parent = screenGui
addCorner(reopenBubble, 24)
addStroke(reopenBubble, COLORS.border, 1)

----------------------------------------------------------------------
-- COUNTDOWN OVERLAY (shown before playback starts)
----------------------------------------------------------------------
local countdownOverlay = Instance.new("Frame")
countdownOverlay.Size = UDim2.new(1, 0, 1, 0)
countdownOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
countdownOverlay.BackgroundTransparency = 0.35
countdownOverlay.Visible = false
countdownOverlay.ZIndex = 30
countdownOverlay.Active = true
countdownOverlay.Parent = rootFrame

local countdownLabel = Instance.new("TextLabel")
countdownLabel.Size = UDim2.new(0, 160, 0, 160)
countdownLabel.AnchorPoint = Vector2.new(0.5, 0.5)
countdownLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
countdownLabel.BackgroundTransparency = 1
countdownLabel.TextColor3 = COLORS.warning
countdownLabel.Font = Enum.Font.GothamBold
countdownLabel.TextSize = 96
countdownLabel.Text = "3"
countdownLabel.ZIndex = 31
countdownLabel.Parent = countdownOverlay

local countdownHintLabel = makeLabel(countdownOverlay, "Tap Stop to cancel", UDim2.new(1, 0, 0, 20), UDim2.new(0, 0, 0.5, 90), 13, Enum.TextXAlignment.Center)
countdownHintLabel.TextColor3 = COLORS.muted
countdownHintLabel.ZIndex = 31

----------------------------------------------------------------------
-- HELP OVERLAY (keyboard / touch control cheat-sheet)
----------------------------------------------------------------------
local helpBackdrop = Instance.new("Frame")
helpBackdrop.Size = UDim2.new(1, 0, 1, 0)
helpBackdrop.BackgroundColor3 = Color3.new(0, 0, 0)
helpBackdrop.BackgroundTransparency = 0.5
helpBackdrop.Visible = false
helpBackdrop.ZIndex = 10
helpBackdrop.Active = true
helpBackdrop.Parent = rootFrame

local helpPanel = makeFrame(
	helpBackdrop,
	isTouchDevice and UDim2.new(0.86, 0, 0.6, 0) or UDim2.new(0, 340, 0, 300),
	isTouchDevice and UDim2.new(0.07, 0, 0.2, 0) or UDim2.new(0.5, -170, 0.5, -150),
	COLORS.panel
)
helpPanel.ZIndex = 11
helpPanel.Active = true
addCorner(helpPanel, 12)
addStroke(helpPanel, COLORS.border, 1)
addPadding(helpPanel, 14, 14, 14, 14)

local helpTitle = makeLabel(helpPanel, "CONTROLS", UDim2.new(1, -30, 0, 22), nil, 16)
helpTitle.Font = Enum.Font.GothamBold
helpTitle.ZIndex = 11

local helpCloseBtn = makeButton(helpPanel, "X", UDim2.new(0, 26, 0, 22), UDim2.new(1, -26, 0, 0), COLORS.danger)
helpCloseBtn.ZIndex = 11

local helpBody = Instance.new("TextLabel")
helpBody.Size = UDim2.new(1, 0, 1, -34)
helpBody.Position = UDim2.new(0, 0, 0, 34)
helpBody.BackgroundTransparency = 1
helpBody.TextColor3 = COLORS.muted
helpBody.Font = Enum.Font.Gotham
helpBody.TextSize = isTouchDevice and 12 or 13
helpBody.TextWrapped = true
helpBody.TextXAlignment = Enum.TextXAlignment.Left
helpBody.TextYAlignment = Enum.TextYAlignment.Top
helpBody.ZIndex = 11
helpBody.Parent = helpPanel
helpBody.Text = isTouchDevice
	and "Thumbstick: move\nUP / DOWN: rise / fall\nDrag empty view: look around\n+ Key / - Key: add / remove keyframe\nTwo-finger tap: stop playback"
	or "W A S D: move\nE / Q: up / down\nRight Mouse + drag: look around\nShift: speed boost, Wheel: adjust speed\nSpace: play / pause\nDelete: remove selected keyframe\nCtrl + D: duplicate selected keyframe\nEsc: stop playback"

----------------------------------------------------------------------
-- RESPONSIVE RELAYOUT (keeps the editor filling the screen with no
-- leftover gaps on every PC and mobile resolution / orientation)
----------------------------------------------------------------------
local function relayout()
	local size = rootFrame.AbsoluteSize
	local sw, sh = size.X, size.Y
	if sw <= 0 or sh <= 0 then return end

	leftPanelWidth = isTouchDevice
		and clamp(math.floor(sw * 0.42), 150, 230)
		or clamp(math.floor(sw * 0.19), 220, 320)
	timelineHeight = isTouchDevice
		and clamp(math.floor(sh * 0.23), 96, 136)
		or clamp(math.floor(sh * 0.20), 140, 180)

	leftPanel.Size = UDim2.new(0, leftPanelWidth, 1, -toolbarHeight - timelineHeight)
	leftPanel.Position = UDim2.new(0, 0, 0, toolbarHeight)

	timeline.Size = UDim2.new(1, 0, 0, timelineHeight)
	timeline.Position = UDim2.new(0, 0, 1, -timelineHeight)

	joystickBase.Position = UDim2.new(0, leftPanelWidth + 8, 1, -(timelineHeight + joystickSize + 10))
	upBtn.Position = UDim2.new(1, -80, 1, -(timelineHeight + 46))
	downBtn.Position = UDim2.new(1, -40, 1, -(timelineHeight + 46))

	refreshRuler()
	refreshTimelineMarkers()
	updatePlayheadVisual()
end

rootFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
relayout()

	return {
		rootFrame = rootFrame,
		playBtn = playBtn,
		pauseBtn = pauseBtn,
		stopBtn = stopBtn,
		addKeyBtn = addKeyBtn,
		removeKeyBtn = removeKeyBtn,
		settingsBtn = settingsBtn,
		helpBtn = helpBtn,
		minimizeBtn = minimizeBtn,
		closeBtn = closeBtn,
		posXBox = posXBox,
		posYBox = posYBox,
		posZBox = posZBox,
		rotXBox = rotXBox,
		rotYBox = rotYBox,
		rotZBox = rotZBox,
		fovBox = fovBox,
		timeBox = timeBox,
		applyFieldsBtn = applyFieldsBtn,
		snapToCameraBtn = snapToCameraBtn,
		duplicateBtn = duplicateBtn,
		deleteBtn = deleteBtn,
		clearAllBtn = clearAllBtn,
		prevKeyBtn = prevKeyBtn,
		restartBtn = restartBtn,
		nextKeyBtn = nextKeyBtn,
		durationBox = durationBox,
		speedBox = speedBox,
		loopBtn = loopBtn,
		easingBtn = easingBtn,
		settingsBackdrop = settingsBackdrop,
		settingsCloseBtn = settingsCloseBtn,
		camSpeedBox = camSpeedBox,
		sensitivityBox = sensitivityBox,
		defaultFovBox = defaultFovBox,
		settingsSpeedBox = settingsSpeedBox,
		settingsEasingBtn = settingsEasingBtn,
		settingsLoopBtn = settingsLoopBtn,
		countdownSecondsBox = countdownSecondsBox,
		applySettingsBtn = applySettingsBtn,
		exportBtn = exportBtn,
		jsonBox = jsonBox,
		importBtn = importBtn,
		dataStatusLabel = dataStatusLabel,
		minimizedBar = minimizedBar,
		restoreBtn = restoreBtn,
		minimizedCloseBtn = minimizedCloseBtn,
		reopenBubble = reopenBubble,
		countdownOverlay = countdownOverlay,
		countdownLabel = countdownLabel,
		helpBackdrop = helpBackdrop,
		helpCloseBtn = helpCloseBtn,
	}
end

local UI = buildUI()

----------------------------------------------------------------------
-- EDITOR OPEN / CLOSE / MINIMIZE LOGIC
----------------------------------------------------------------------
local renderConnection = nil

local function applyCameraScriptable()
	if not camera then camera = Workspace.CurrentCamera end
	if not camera then return end
	camera.CameraType = Enum.CameraType.Scriptable
end

local function restoreOriginalCamera()
	if not camera then camera = Workspace.CurrentCamera end
	if not camera then return end
	camera.CameraType = originalCameraType
	camera.FieldOfView = originalFOV
	if originalCameraSubject then
		camera.CameraSubject = originalCameraSubject
	end
end

local function mainRenderStep(dt)
	if not camera or camera ~= Workspace.CurrentCamera then
		camera = Workspace.CurrentCamera
		if editorOpen then
			applyCameraScriptable()
		end
	end
	if not camera then return end

	if isPlaying then
		if not isPaused then
			currentTime = currentTime + dt * playbackSpeed
			if currentTime >= duration then
				if loopPlayback then
					currentTime = currentTime % math.max(duration, 0.0001)
				else
					currentTime = duration
					isPlaying = false
					isPaused = false
				end
			end
		end
		local cf, fov = getCameraStateAtTime(currentTime)
		if cf then
			camera.CFrame = cf
			camera.FieldOfView = fov or currentFOV
			freeCamCFrame = cf
		end
		updatePlayheadVisual()
		updateTimeDisplays()
		if not isPlaying then
			restoreAllPlaybackGuis()
		end
	else
		-- FREE CAMERA MODE -------------------------------------------------
		local focusedBox = UserInputService:GetFocusedTextBox()
		if not focusedBox then
			-- Keyboard movement
			local moveVector = Vector3.new(0, 0, 0)
			if moveState.forward then moveVector = moveVector + freeCamCFrame.LookVector end
			if moveState.backward then moveVector = moveVector - freeCamCFrame.LookVector end
			if moveState.right then moveVector = moveVector + freeCamCFrame.RightVector end
			if moveState.left then moveVector = moveVector - freeCamCFrame.RightVector end
			if moveVector.Magnitude > 0 then
				moveVector = moveVector.Unit
			end

			-- Joystick movement (mobile) adds on top of keyboard movement.
			if joystickActive and joystickDir.Magnitude > 0 then
				local strafe = freeCamCFrame.RightVector * joystickDir.X
				local forward = freeCamCFrame.LookVector * -joystickDir.Z
				moveVector = moveVector + strafe + forward
				if moveVector.Magnitude > 1 then
					moveVector = moveVector.Unit
				end
			end

			local vertical = 0
			if moveState.up then vertical = vertical + 1 end
			if moveState.down then vertical = vertical - 1 end

			local speed = camMoveSpeed * (shiftHeld and 2.5 or 1)
			local translation = (moveVector * speed) + Vector3.new(0, vertical * speed, 0)
			if translation.Magnitude > 0 then
				freeCamCFrame = freeCamCFrame + translation * dt
			end
		end

		camera.CFrame = freeCamCFrame
		camera.FieldOfView = currentFOV
		updatePlayheadVisual()
		updateTimeDisplays()
	end
end

local function startRenderLoop()
	if renderConnection then return end
	renderConnection = RunService.RenderStepped:Connect(mainRenderStep)
end

local function stopRenderLoop()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

local function openEditor()
	if editorOpen then return end
	editorOpen = true
	editorOpenRef = true
	editorMinimized = false
	UI.rootFrame.Visible = true
	UI.minimizedBar.Visible = false
	UI.reopenBubble.Visible = false
	camera = Workspace.CurrentCamera
	applyCameraScriptable()
	camera.FieldOfView = currentFOV
	freeCamCFrame = camera.CFrame
	startRenderLoop()
	refreshKeyframeList()
	refreshTimelineMarkers()
	refreshSelectedPanel()
	refreshRuler()
	refreshCurveGraph()
	updatePlayheadVisual()
	updateTimeDisplays()
end

local function closeEditor()
	if not editorOpen then return end
	if countdownActive and cancelCountdown then cancelCountdown() end
	restoreAllPlaybackGuis()
	editorOpen = false
	editorOpenRef = false
	editorMinimized = false
	isPlaying = false
	isPaused = false
	UI.rootFrame.Visible = false
	UI.minimizedBar.Visible = false
	UI.reopenBubble.Visible = true
	UI.settingsBackdrop.Visible = false
	UI.helpBackdrop.Visible = false
	stopRenderLoop()
	restoreOriginalCamera()
	-- Reset transient input state so nothing "sticks" after closing.
	moveState = { forward = false, backward = false, left = false, right = false, up = false, down = false }
	shiftHeld = false
	ctrlHeld = false
	rightMouseDown = false
	resetJoystick()
	touchLookActive = false
end

local function minimizeEditor()
	if not editorOpen then return end
	editorMinimized = true
	UI.rootFrame.Visible = false
	UI.minimizedBar.Visible = true
	UI.settingsBackdrop.Visible = false
	UI.helpBackdrop.Visible = false
	-- Keep the render loop running so the camera stays scriptable and
	-- in place while minimized, but movement input still works if desired.
end

local function restoreFromMinimized()
	if not editorOpen then return end
	editorMinimized = false
	UI.rootFrame.Visible = true
	UI.minimizedBar.Visible = false
end

----------------------------------------------------------------------
-- PLAYBACK CONTROL FUNCTIONS
----------------------------------------------------------------------
seekTo = function(t)
	currentTime = clamp(t, 0, duration)
	local cf, fov = getCameraStateAtTime(currentTime)
	if cf then
		freeCamCFrame = cf
		currentFOV = fov or currentFOV
		if camera then
			camera.CFrame = cf
			camera.FieldOfView = currentFOV
		end
	end
	updatePlayheadVisual()
	updateTimeDisplays()
end

local function playPlayback()
	if #keyframes == 0 then return end
	if currentTime >= duration then
		currentTime = 0
	end
	hideAllPlaybackGuis()
	isPlaying = true
	isPaused = false
end

-- Shows a short countdown over the still-visible editor UI, then hides every
-- GUI (including the two core Roblox topbar buttons) and starts playback.
local function runCountdownThenPlay()
	if #keyframes == 0 then return end
	if countdownActive then return end

	local seconds = math.floor(countdownSeconds)
	if seconds <= 0 then
		playPlayback()
		return
	end

	countdownActive = true
	local cancelled = false
	cancelCountdown = function()
		cancelled = true
		countdownActive = false
		UI.countdownOverlay.Visible = false
	end

	UI.countdownOverlay.Visible = true
	local remaining = seconds

	local function tick()
		if cancelled then return end
		if remaining <= 0 then
			UI.countdownOverlay.Visible = false
			countdownActive = false
			playPlayback()
			return
		end
		UI.countdownLabel.Text = tostring(remaining)
		UI.countdownLabel.Size = UDim2.new(0, 190, 0, 190)
		local tween = TweenService:Create(UI.countdownLabel, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.new(0, 160, 0, 160) })
		tween:Play()
		remaining = remaining - 1
		task.delay(1, tick)
	end
	tick()
end

local function pausePlayback()
	if isPlaying then
		isPaused = true
	end
end

local function resumePlayback()
	if isPlaying and isPaused then
		isPaused = false
	end
end

local function stopPlayback()
	if countdownActive and cancelCountdown then cancelCountdown() end
	isPlaying = false
	isPaused = false
	seekTo(0)
	restoreAllPlaybackGuis()
end

local function restartPlayback()
	if #keyframes == 0 then return end
	if countdownActive and cancelCountdown then cancelCountdown() end
	currentTime = 0
	hideAllPlaybackGuis()
	isPlaying = true
	isPaused = false
end

-- Shared by the toolbar Play button and the Space shortcut.
local function handlePlayButtonPress()
	if isPlaying and isPaused then
		resumePlayback()
	elseif isPlaying then
		pausePlayback()
	else
		runCountdownThenPlay()
	end
end

local function gotoPreviousKeyframe()
	local best = nil
	for _, kf in ipairs(keyframes) do
		if kf.time < currentTime - TIME_EPSILON then
			if not best or kf.time > best.time then
				best = kf
			end
		end
	end
	if best then
		seekTo(best.time)
		selectKeyframe(best)
	elseif #keyframes > 0 then
		seekTo(keyframes[1].time)
	end
end

local function gotoNextKeyframe()
	local best = nil
	for _, kf in ipairs(keyframes) do
		if kf.time > currentTime + TIME_EPSILON then
			if not best or kf.time < best.time then
				best = kf
			end
		end
	end
	if best then
		seekTo(best.time)
		selectKeyframe(best)
	elseif #keyframes > 0 then
		seekTo(keyframes[#keyframes].time)
	end
end

----------------------------------------------------------------------
-- JSON EXPORT / IMPORT
----------------------------------------------------------------------
local function exportKeyframes()
	local data = {
		duration = duration,
		easing = easingMode,
		loop = loopPlayback,
		countdown = countdownSeconds,
		keyframes = {},
	}
	for _, kf in ipairs(keyframes) do
		local pos = kf.cframe.Position
		local rx, ry, rz = kf.cframe:ToOrientation()
		table.insert(data.keyframes, {
			time = kf.time,
			fov = kf.fov,
			position = { x = pos.X, y = pos.Y, z = pos.Z },
			rotation = { x = math.deg(rx), y = math.deg(ry), z = math.deg(rz) },
		})
	end
	local ok, json = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if ok then
		UI.jsonBox.Text = json
		UI.dataStatusLabel.Text = "Exported " .. #keyframes .. " keyframe(s)."
		UI.dataStatusLabel.TextColor3 = COLORS.success
	else
		UI.dataStatusLabel.Text = "Export failed."
		UI.dataStatusLabel.TextColor3 = COLORS.danger
	end
end

local function importKeyframes()
	local raw = UI.jsonBox.Text
	if not raw or raw == "" then
		UI.dataStatusLabel.Text = "Nothing to import."
		UI.dataStatusLabel.TextColor3 = COLORS.danger
		return
	end
	local ok, result = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or type(result) ~= "table" then
		UI.dataStatusLabel.Text = "Invalid JSON - import cancelled."
		UI.dataStatusLabel.TextColor3 = COLORS.danger
		return
	end
	if type(result.keyframes) ~= "table" then
		UI.dataStatusLabel.Text = "JSON missing 'keyframes' array."
		UI.dataStatusLabel.TextColor3 = COLORS.danger
		return
	end

	local newKeyframes = {}
	for _, entry in ipairs(result.keyframes) do
		local okEntry = type(entry) == "table"
			and type(entry.time) == "number"
			and type(entry.fov) == "number"
			and type(entry.position) == "table"
			and type(entry.rotation) == "table"
			and type(entry.position.x) == "number"
			and type(entry.position.y) == "number"
			and type(entry.position.z) == "number"
			and type(entry.rotation.x) == "number"
			and type(entry.rotation.y) == "number"
			and type(entry.rotation.z) == "number"
		if okEntry then
			local pos = Vector3.new(entry.position.x, entry.position.y, entry.position.z)
			local cf = CFrame.new(pos) * CFrame.fromOrientation(
				math.rad(entry.rotation.x),
				math.rad(entry.rotation.y),
				math.rad(entry.rotation.z)
			)
			keyframeIdCounter = keyframeIdCounter + 1
			table.insert(newKeyframes, { id = keyframeIdCounter, cframe = cf, fov = entry.fov, time = entry.time })
		end
	end

	if #newKeyframes == 0 then
		UI.dataStatusLabel.Text = "No valid keyframes found in JSON."
		UI.dataStatusLabel.TextColor3 = COLORS.danger
		return
	end

	keyframes = newKeyframes
	sortKeyframes()
	selectedKeyframe = nil

	if type(result.duration) == "number" and result.duration > 0 then
		duration = result.duration
		UI.durationBox.Text = tostring(duration)
	end
	if type(result.loop) == "boolean" then
		loopPlayback = result.loop
		UI.loopBtn.Text = isTouchDevice and (loopPlayback and "Loop On" or "Loop Off") or (loopPlayback and "Loop: On" or "Loop: Off")
		UI.settingsLoopBtn.Text = loopPlayback and "On" or "Off"
	end
	if type(result.countdown) == "number" then
		countdownSeconds = clamp(math.floor(result.countdown), 0, 15)
		UI.countdownSecondsBox.Text = tostring(countdownSeconds)
	end
	if type(result.easing) == "string" then
		for i, mode in ipairs(EASING_MODES) do
			if mode == result.easing then
				easingModeIndex = i
				easingMode = mode
				UI.easingBtn.Text = "Ease: " .. easingMode
				UI.settingsEasingBtn.Text = easingMode
				break
			end
		end
	end

	refreshKeyframeList()
	refreshTimelineMarkers()
	refreshRuler()
	refreshSelectedPanel()
	refreshCurveGraph()
	seekTo(0)

	UI.dataStatusLabel.Text = "Imported " .. #newKeyframes .. " keyframe(s)."
	UI.dataStatusLabel.TextColor3 = COLORS.success
end

----------------------------------------------------------------------
-- BUTTON / INPUT WIRING
----------------------------------------------------------------------

-- Toolbar
UI.playBtn.Activated:Connect(handlePlayButtonPress)
UI.pauseBtn.Activated:Connect(pausePlayback)
UI.stopBtn.Activated:Connect(stopPlayback)
UI.addKeyBtn.Activated:Connect(function()
	addKeyframe(currentTime, freeCamCFrame, currentFOV)
end)
UI.removeKeyBtn.Activated:Connect(quickRemoveKeyframe)
UI.settingsBtn.Activated:Connect(function()
	UI.settingsBackdrop.Visible = not UI.settingsBackdrop.Visible
	UI.helpBackdrop.Visible = false
end)
UI.helpBtn.Activated:Connect(function()
	UI.helpBackdrop.Visible = not UI.helpBackdrop.Visible
	UI.settingsBackdrop.Visible = false
end)
UI.helpCloseBtn.Activated:Connect(function()
	UI.helpBackdrop.Visible = false
end)
UI.minimizeBtn.Activated:Connect(minimizeEditor)
UI.closeBtn.Activated:Connect(closeEditor)
UI.restoreBtn.Activated:Connect(restoreFromMinimized)
UI.minimizedCloseBtn.Activated:Connect(closeEditor)
UI.reopenBubble.Activated:Connect(openEditor)

-- Timeline controls
UI.prevKeyBtn.Activated:Connect(gotoPreviousKeyframe)
UI.nextKeyBtn.Activated:Connect(gotoNextKeyframe)
UI.restartBtn.Activated:Connect(restartPlayback)

UI.loopBtn.Activated:Connect(function()
	loopPlayback = not loopPlayback
	UI.loopBtn.Text = isTouchDevice and (loopPlayback and "Loop On" or "Loop Off") or (loopPlayback and "Loop: On" or "Loop: Off")
	UI.loopBtn.BackgroundColor3 = loopPlayback and COLORS.accent or COLORS.buttonBg
	UI.settingsLoopBtn.Text = loopPlayback and "On" or "Off"
	UI.settingsLoopBtn.BackgroundColor3 = loopPlayback and COLORS.accent or COLORS.buttonBg
end)

UI.easingBtn.Activated:Connect(function()
	easingModeIndex = (easingModeIndex % #EASING_MODES) + 1
	easingMode = EASING_MODES[easingModeIndex]
	UI.easingBtn.Text = "Ease: " .. easingMode
	UI.settingsEasingBtn.Text = easingMode
	refreshCurveGraph()
end)

UI.durationBox.FocusLost:Connect(function(enterPressed)
	local n = tonumber(UI.durationBox.Text)
	if n and n > 0 then
		duration = n
		currentTime = clamp(currentTime, 0, duration)
		refreshRuler()
		refreshTimelineMarkers()
		updatePlayheadVisual()
		updateTimeDisplays()
	end
	UI.durationBox.Text = tostring(duration)
end)

UI.speedBox.FocusLost:Connect(function()
	local n = tonumber(UI.speedBox.Text)
	if n and n > 0 then
		playbackSpeed = n
		UI.settingsSpeedBox.Text = tostring(playbackSpeed)
	end
	UI.speedBox.Text = tostring(playbackSpeed)
end)

-- Settings panel
UI.settingsCloseBtn.Activated:Connect(function()
	UI.settingsBackdrop.Visible = false
end)

UI.settingsLoopBtn.Activated:Connect(function()
	loopPlayback = not loopPlayback
	UI.loopBtn.Text = isTouchDevice and (loopPlayback and "Loop On" or "Loop Off") or (loopPlayback and "Loop: On" or "Loop: Off")
	UI.loopBtn.BackgroundColor3 = loopPlayback and COLORS.accent or COLORS.buttonBg
	UI.settingsLoopBtn.Text = loopPlayback and "On" or "Off"
	UI.settingsLoopBtn.BackgroundColor3 = loopPlayback and COLORS.accent or COLORS.buttonBg
end)

UI.applySettingsBtn.Activated:Connect(function()
	local s = tonumber(UI.camSpeedBox.Text)
	if s and s > 0 then camMoveSpeed = s end
	UI.camSpeedBox.Text = tostring(camMoveSpeed)

	local sens = tonumber(UI.sensitivityBox.Text)
	if sens and sens > 0 then camSensitivity = sens end
	UI.sensitivityBox.Text = tostring(camSensitivity)

	local fov = tonumber(UI.defaultFovBox.Text)
	if fov and fov > 0 and fov < 170 then
		defaultFOV = fov
		if not isPlaying then
			currentFOV = fov
		end
	end
	UI.defaultFovBox.Text = tostring(defaultFOV)

	local spd = tonumber(UI.settingsSpeedBox.Text)
	if spd and spd > 0 then
		playbackSpeed = spd
		UI.speedBox.Text = tostring(playbackSpeed)
	end
	UI.settingsSpeedBox.Text = tostring(playbackSpeed)

	local cd = tonumber(UI.countdownSecondsBox.Text)
	if cd and cd >= 0 then
		countdownSeconds = clamp(math.floor(cd), 0, 15)
	end
	UI.countdownSecondsBox.Text = tostring(countdownSeconds)
end)

UI.exportBtn.Activated:Connect(exportKeyframes)
UI.importBtn.Activated:Connect(importKeyframes)

-- Left panel: Apply manual field edits to the selected keyframe
UI.applyFieldsBtn.Activated:Connect(function()
	if not selectedKeyframe then return end
	local kf = selectedKeyframe

	local px = tonumber(UI.posXBox.Text) or kf.cframe.Position.X
	local py = tonumber(UI.posYBox.Text) or kf.cframe.Position.Y
	local pz = tonumber(UI.posZBox.Text) or kf.cframe.Position.Z
	local rx = tonumber(UI.rotXBox.Text) or 0
	local ry = tonumber(UI.rotYBox.Text) or 0
	local rz = tonumber(UI.rotZBox.Text) or 0
	local fov = tonumber(UI.fovBox.Text) or kf.fov
	local newTime = tonumber(UI.timeBox.Text) or kf.time

	kf.cframe = CFrame.new(px, py, pz) * CFrame.fromOrientation(math.rad(rx), math.rad(ry), math.rad(rz))
	kf.fov = clamp(fov, 1, 169)

	if math.abs(newTime - kf.time) > 1e-4 then
		moveKeyframeTiming(kf, newTime)
	end

	refreshKeyframeList()
	refreshTimelineMarkers()
	refreshSelectedPanel()
	seekTo(currentTime) -- refresh preview if the edited keyframe affects current pose
end)

UI.snapToCameraBtn.Activated:Connect(function()
	if not selectedKeyframe then return end
	selectedKeyframe.cframe = freeCamCFrame
	selectedKeyframe.fov = currentFOV
	refreshSelectedPanel()
	refreshTimelineMarkers()
end)

UI.duplicateBtn.Activated:Connect(duplicateKeyframe)
UI.deleteBtn.Activated:Connect(deleteSelectedKeyframe)

-- Clear All requires a confirming second tap within 3 seconds (safety against
-- accidentally wiping every keyframe with one stray touch).
local clearAllArmed = false
local clearAllArmTimer = nil
UI.clearAllBtn.Activated:Connect(function()
	if #keyframes == 0 then return end
	if not clearAllArmed then
		clearAllArmed = true
		UI.clearAllBtn.Text = "Tap again to confirm"
		UI.clearAllBtn.BackgroundColor3 = COLORS.danger
		if clearAllArmTimer then task.cancel(clearAllArmTimer) end
		clearAllArmTimer = task.delay(3, function()
			clearAllArmed = false
			UI.clearAllBtn.Text = "Clear All Keyframes"
			UI.clearAllBtn.BackgroundColor3 = COLORS.dangerDim
		end)
	else
		clearAllArmed = false
		if clearAllArmTimer then task.cancel(clearAllArmTimer) end
		UI.clearAllBtn.Text = "Clear All Keyframes"
		UI.clearAllBtn.BackgroundColor3 = COLORS.dangerDim
		clearAllKeyframes()
	end
end)

----------------------------------------------------------------------
-- KEYBOARD / MOUSE INPUT (desktop)
----------------------------------------------------------------------
local playbackTouchInputs = {}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Playback hides every GUI, so two fingers anywhere on the screen is the mobile stop gesture.
	if isPlaying and input.UserInputType == Enum.UserInputType.Touch then
		playbackTouchInputs[input] = true
		local touchCount = 0
		for _ in pairs(playbackTouchInputs) do
			touchCount = touchCount + 1
		end
		if touchCount >= 2 then
			table.clear(playbackTouchInputs)
			stopPlayback()
		end
		return
	end

	if not editorOpen or editorMinimized then return end
	if UserInputService:GetFocusedTextBox() then return end

	if input.UserInputType == Enum.UserInputType.Keyboard then
		local key = input.KeyCode
		if key == Enum.KeyCode.Escape then
			if countdownActive then
				if cancelCountdown then cancelCountdown() end
			elseif isPlaying then
				stopPlayback()
			end
			return
		end
		if key == Enum.KeyCode.Space then
			handlePlayButtonPress()
			return
		end
		if not isPlaying then
			if key == Enum.KeyCode.W then moveState.forward = true
			elseif key == Enum.KeyCode.S then moveState.backward = true
			elseif key == Enum.KeyCode.A then moveState.left = true
			elseif key == Enum.KeyCode.D then
				if ctrlHeld then duplicateKeyframe() else moveState.right = true end
			elseif key == Enum.KeyCode.E then moveState.up = true
			elseif key == Enum.KeyCode.Q then moveState.down = true
			elseif key == Enum.KeyCode.Delete or key == Enum.KeyCode.Backspace then
				deleteSelectedKeyframe()
			elseif key == Enum.KeyCode.LeftShift or key == Enum.KeyCode.RightShift then shiftHeld = true
			elseif key == Enum.KeyCode.LeftControl or key == Enum.KeyCode.RightControl then ctrlHeld = true
			end
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		if not isPlaying then
			rightMouseDown = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		playbackTouchInputs[input] = nil
	end

	if input.UserInputType == Enum.UserInputType.Keyboard then
		local key = input.KeyCode
		if key == Enum.KeyCode.W then moveState.forward = false
		elseif key == Enum.KeyCode.S then moveState.backward = false
		elseif key == Enum.KeyCode.A then moveState.left = false
		elseif key == Enum.KeyCode.D then moveState.right = false
		elseif key == Enum.KeyCode.E then moveState.up = false
		elseif key == Enum.KeyCode.Q then moveState.down = false
		elseif key == Enum.KeyCode.LeftShift or key == Enum.KeyCode.RightShift then shiftHeld = false
		elseif key == Enum.KeyCode.LeftControl or key == Enum.KeyCode.RightControl then ctrlHeld = false
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		rightMouseDown = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end

	if input.UserInputType == Enum.UserInputType.Touch and touchLookActive and input == touchLookId then
		touchLookActive = false
		touchLookId = nil
		lastTouchPos = nil
	end
end)

-- Mouse look (right mouse drag) + mouse wheel (speed) + touch-drag look
UserInputService.InputChanged:Connect(function(input)
	if not editorOpen or editorMinimized or isPlaying then return end

	if input.UserInputType == Enum.UserInputType.MouseMovement and rightMouseDown then
		local delta = input.Delta
		local pos = freeCamCFrame.Position
		-- Recompute yaw/pitch fresh each time to avoid gimbal drift accumulation issues.
		local rx, ry, rz = freeCamCFrame:ToOrientation()
		local yaw = ry - math.rad(delta.X * camSensitivity)
		local pitch = clamp(rx - math.rad(delta.Y * camSensitivity), math.rad(-89), math.rad(89))
		freeCamCFrame = CFrame.new(pos) * CFrame.fromOrientation(pitch, yaw, 0)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		camMoveSpeed = clamp(camMoveSpeed + input.Position.Z * 5, 5, 400)
		UI.camSpeedBox.Text = tostring(camMoveSpeed)
	elseif input.UserInputType == Enum.UserInputType.Touch and touchLookActive and input == touchLookId then
		if lastTouchPos then
			local delta = input.Position - lastTouchPos
			local pos = freeCamCFrame.Position
			local rx, ry, rz = freeCamCFrame:ToOrientation()
			local yaw = ry - math.rad(delta.X * camSensitivity)
			local pitch = clamp(rx - math.rad(delta.Y * camSensitivity), math.rad(-89), math.rad(89))
			freeCamCFrame = CFrame.new(pos) * CFrame.fromOrientation(pitch, yaw, 0)
		end
		lastTouchPos = input.Position
	end
end)

----------------------------------------------------------------------
-- CHARACTER RESPAWN / CAMERA RE-ASSERTION
----------------------------------------------------------------------
player.CharacterAdded:Connect(function()
	-- Re-apply scriptable camera settings if the editor is active, since
	-- Roblox resets CameraType/CameraSubject to follow the new character.
	task.defer(function()
		if editorOpen then
			camera = Workspace.CurrentCamera
			applyCameraScriptable()
			camera.CFrame = freeCamCFrame
			camera.FieldOfView = currentFOV
		end
	end)
end)

----------------------------------------------------------------------
-- CLEANUP ON PLAYER / SCRIPT TEARDOWN
----------------------------------------------------------------------
player.AncestryChanged:Connect(function(_, parent)
	if not parent then
		restoreAllPlaybackGuis()
		if editorOpen then
			restoreOriginalCamera()
		end
		stopRenderLoop()
	end
end)

-- Do not rely on the global `script` object here. Some local script runners
-- execute the code without providing it, which would stop initialization.

----------------------------------------------------------------------
-- INITIALIZE
-- Open the editor immediately so there is a visible result when this
-- LocalScript is started. The reopen bubble is used after the editor closes.
----------------------------------------------------------------------
refreshRuler()
refreshKeyframeList()
refreshTimelineMarkers()
refreshSelectedPanel()
refreshCurveGraph()
updatePlayheadVisual()
updateTimeDisplays()
openEditor()
print("[Camera Keyframe Editor] Started successfully")
