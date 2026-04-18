--[[
	Reactor Relay
	Single-script Roblox demo authored to showcase broad API knowledge in one readable file.

	The script builds its own arena at runtime, so the place can stay minimal while the code
	remains the single source of truth for the demo. The gameplay loop is:

	1. Spawn on the central launch platform.
	2. Use ballistic launch pads to reach four outer relay stations.
	3. Touch checkpoints and stabilize each relay with a ProximityPrompt.
	4. When all relays are active, rotating hazards slow down, bridges deploy, and the core
	   reward pad unlocks for a timed scoring window.

	The implementation deliberately demonstrates several Roblox concepts in one script:
	- DataModel construction through Instance APIs.
	- CFrame math for orbiting hazards and decorative drones.
	- Physics math for deterministic launch pad trajectories.
	- Metatables for controller-style objects.
	- Spatial queries with OverlapParams and GetPartBoundsInBox.
	- ProximityPrompt, TweenService, Debris, Attributes, CollectionService, and PhysicsService.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")

local WORLD_NAME = "ReactorRelayDemo"
local DECOR_GROUP = "ArenaDecor"
local Y_AXIS = Vector3.new(0, 1, 0)

local CONFIG = table.freeze({
	HubHeight = 12,
	StationHeight = 24,
	HubRadius = 26,
	StationRadius = 118,
	CoreRewardRadius = 18,
	BridgeInnerRadius = 28,
	RespawnFloorY = -30,
	LaunchFlightTime = 0.92,
	ReturnFlightTime = 0.85,
	HazardDamage = 30,
	HazardHitCooldown = 1.15,
	StableDuration = 22,
	CheckpointScore = 20,
	NodeScore = 60,
	CoreScore = 140,
	StabilizationBonus = 100,
	SurvivalTickSeconds = 1,
	SurvivalTickScore = 3,
})

local relayNames = { "North", "East", "South", "West" }

local function create(className, properties, children)
	local instance = Instance.new(className)

	for property, value in pairs(properties or {}) do
		if property ~= "Parent" then
			instance[property] = value
		end
	end

	for _, child in ipairs(children or {}) do
		child.Parent = instance
	end

	instance.Parent = properties and properties.Parent or nil
	return instance
end

local function withAlpha(color, alpha)
	return Color3.new(color.R + (1 - color.R) * alpha, color.G + (1 - color.G) * alpha, color.B + (1 - color.B) * alpha)
end

local function getCharacterRoot(character)
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart")
end

local function getPlayerFromHit(hit)
	local character = hit and hit:FindFirstAncestorOfClass("Model")
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil, nil, nil
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return nil, nil, nil
	end

	return player, character, humanoid
end

local function setCollisionGroupRecursive(root, groupName)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end
end

local function ensureCollisionGroup(name)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

ensureCollisionGroup(DECOR_GROUP)
PhysicsService:CollisionGroupSetCollidable(DECOR_GROUP, "Default", false)
PhysicsService:CollisionGroupSetCollidable(DECOR_GROUP, DECOR_GROUP, false)

local existingWorld = workspace:FindFirstChild(WORLD_NAME)
if existingWorld then
	existingWorld:Destroy()
end

local world = create("Folder", {
	Name = WORLD_NAME,
	Parent = workspace,
})

local geometryFolder = create("Folder", {
	Name = "Geometry",
	Parent = world,
})

local effectsFolder = create("Folder", {
	Name = "Effects",
	Parent = world,
})

Lighting.Ambient = Color3.fromRGB(28, 30, 44)
Lighting.OutdoorAmbient = Color3.fromRGB(40, 48, 62)
Lighting.Brightness = 2.4
Lighting.ClockTime = 19.25

if not Lighting:FindFirstChild("ReactorRelayBloom") then
	create("BloomEffect", {
		Name = "ReactorRelayBloom",
		Intensity = 0.3,
		Size = 18,
		Threshold = 1.1,
		Parent = Lighting,
	})
end

if not Lighting:FindFirstChild("ReactorRelayAtmosphere") then
	create("Atmosphere", {
		Name = "ReactorRelayAtmosphere",
		Color = Color3.fromRGB(114, 148, 196),
		Decay = Color3.fromRGB(16, 22, 32),
		Density = 0.32,
		Offset = 0.1,
		Glare = 0.05,
		Haze = 1.4,
		Parent = Lighting,
	})
end

local Janitor = {}
Janitor.__index = Janitor

function Janitor.new()
	return setmetatable({
		_tasks = {},
	}, Janitor)
end

function Janitor:add(task)
	table.insert(self._tasks, task)
	return task
end

function Janitor:cleanup()
	for index = #self._tasks, 1, -1 do
		local task = self._tasks[index]
		local kind = typeof(task)

		if kind == "RBXScriptConnection" then
			task:Disconnect()
		elseif kind == "Instance" then
			task:Destroy()
		elseif kind == "function" then
			task()
		elseif type(task) == "table" then
			if task.cleanup then
				task:cleanup()
			elseif task.destroy then
				task:destroy()
			end
		end

		self._tasks[index] = nil
	end
end

local function addLabel(parent, text, studsOffset, color)
	return create("BillboardGui", {
		Adornee = parent,
		AlwaysOnTop = true,
		ExtentsOffsetWorldSpace = studsOffset,
		LightInfluence = 0,
		Size = UDim2.fromOffset(220, 60),
		Parent = parent,
	}, {
		create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			Text = text,
			TextColor3 = color,
			TextScaled = true,
			TextStrokeTransparency = 0.6,
		}),
	})
end

local function addSurfacePanel(part, face, header, body)
	local panel = create("SurfaceGui", {
		Face = face,
		LightInfluence = 0,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 48,
		CanvasSize = Vector2.new(720, 420),
		Parent = part,
	})

	create("Frame", {
		BackgroundColor3 = Color3.fromRGB(16, 19, 28),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = panel,
	}, {
		create("UICorner", {
			CornerRadius = UDim.new(0, 24),
		}),
		create("UIStroke", {
			Color = Color3.fromRGB(96, 205, 255),
			Transparency = 0.2,
			Thickness = 4,
		}),
		create("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBlack,
			Position = UDim2.fromScale(0.06, 0.08),
			Size = UDim2.fromScale(0.88, 0.18),
			Text = header,
			TextColor3 = Color3.fromRGB(232, 245, 255),
			TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		create("TextLabel", {
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamMedium,
			Position = UDim2.fromScale(0.06, 0.3),
			Size = UDim2.fromScale(0.88, 0.54),
			Text = body,
			TextColor3 = Color3.fromRGB(202, 217, 235),
			TextScaled = true,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}),
	})
end

local function computeBallisticVelocity(origin, target, flightTime)
	local displacement = target - origin
	local horizontalDisplacement = Vector3.new(displacement.X, 0, displacement.Z)
	local horizontalVelocity = horizontalDisplacement / flightTime
	local verticalVelocity = (displacement.Y + 0.5 * workspace.Gravity * flightTime * flightTime) / flightTime
	return horizontalVelocity + Y_AXIS * verticalVelocity
end

local function awardScore(player, amount)
	local leaderstats = player:FindFirstChild("leaderstats")
	local scoreValue = leaderstats and leaderstats:FindFirstChild("Score")

	if scoreValue then
		scoreValue.Value += amount
	end
end

local function awardStat(player, name, amount)
	local leaderstats = player:FindFirstChild("leaderstats")
	local statValue = leaderstats and leaderstats:FindFirstChild(name)

	if statValue then
		statValue.Value += amount
	end
end

local playerStateByUserId = {}

local function getPlayerState(player)
	local state = playerStateByUserId[player.UserId]
	if state then
		return state
	end

	state = {
		CheckpointCFrame = CFrame.new(0, CONFIG.HubHeight + 5, 0),
		LastCheckpointName = "Hub",
		VisitedCheckpoints = {},
		LastHazardHit = 0,
		LastLaunchTick = 0,
		ClaimedCoreCycle = 0,
		PendingRespawn = false,
		NextSurvivalTick = 0,
	}

	playerStateByUserId[player.UserId] = state
	return state
end

local outerStations = {}
local movingDrones = {}
local hazardBeams = {}
local bridgeParts = {}

local gameState = {
	ActiveNodeCount = 0,
	IsStable = false,
	CycleNumber = 0,
	StableEndsAt = 0,
}

local hubPad = create("Part", {
	Name = "HubPad",
	Anchored = true,
	CanCollide = true,
	Color = Color3.fromRGB(32, 43, 64),
	Material = Enum.Material.Metal,
	Shape = Enum.PartType.Cylinder,
	Size = Vector3.new(4, CONFIG.HubRadius * 2, CONFIG.HubRadius * 2),
	Orientation = Vector3.new(0, 0, 90),
	Position = Vector3.new(0, CONFIG.HubHeight, 0),
	Parent = geometryFolder,
})

local hubTrim = create("Part", {
	Name = "HubTrim",
	Anchored = true,
	CanCollide = false,
	Color = Color3.fromRGB(96, 205, 255),
	Material = Enum.Material.Neon,
	Shape = Enum.PartType.Cylinder,
	Size = Vector3.new(1.5, CONFIG.HubRadius * 1.78, CONFIG.HubRadius * 1.78),
	Orientation = Vector3.new(0, 0, 90),
	Position = hubPad.Position + Vector3.new(0, 1.75, 0),
	Parent = geometryFolder,
})

local instructionWall = create("Part", {
	Name = "InstructionWall",
	Anchored = true,
	CanCollide = true,
	Color = Color3.fromRGB(12, 16, 24),
	Material = Enum.Material.Metal,
	Size = Vector3.new(24, 14, 1),
	CFrame = CFrame.new(0, CONFIG.HubHeight + 9, CONFIG.HubRadius + 8),
	Parent = geometryFolder,
})

addSurfacePanel(
	instructionWall,
	Enum.NormalId.Back,
	"Reactor Relay",
	"Step on a launch pad to reach a relay station. Touch the checkpoint, use the stabilizer prompt, then return for the next relay. When all four relays are active, bridges deploy and the reactor core opens for bonus score."
)

addSurfacePanel(
	instructionWall,
	Enum.NormalId.Front,
	"Demo Notes",
	"This arena is generated entirely by one server script. It demonstrates CFrame motion, physics launches, prompts, overlap-based hazards, metatable controllers, attributes, and runtime world construction."
)

local coreRing = create("Part", {
	Name = "CoreRing",
	Anchored = true,
	CanCollide = true,
	Color = Color3.fromRGB(42, 52, 72),
	Material = Enum.Material.DiamondPlate,
	Shape = Enum.PartType.Cylinder,
	Size = Vector3.new(4, CONFIG.CoreRewardRadius * 2.4, CONFIG.CoreRewardRadius * 2.4),
	Orientation = Vector3.new(0, 0, 90),
	Position = Vector3.new(0, CONFIG.StationHeight - 2, 0),
	Parent = geometryFolder,
})

local coreRewardPad = create("Part", {
	Name = "CoreRewardPad",
	Anchored = true,
	CanCollide = false,
	Color = Color3.fromRGB(255, 205, 76),
	Material = Enum.Material.Neon,
	Shape = Enum.PartType.Cylinder,
	Size = Vector3.new(2.5, 16, 16),
	Orientation = Vector3.new(0, 0, 90),
	Position = Vector3.new(0, CONFIG.StationHeight + 0.3, 0),
	Transparency = 0.55,
	Parent = geometryFolder,
})

local coreColumn = create("Part", {
	Name = "CoreColumn",
	Anchored = true,
	CanCollide = true,
	Color = Color3.fromRGB(24, 31, 44),
	Material = Enum.Material.Metal,
	Shape = Enum.PartType.Cylinder,
	Size = Vector3.new(CONFIG.StationHeight, 10, 10),
	Orientation = Vector3.new(0, 0, 90),
	Position = Vector3.new(0, CONFIG.StationHeight / 2, 0),
	Parent = geometryFolder,
})

local reactorCore = create("Part", {
	Name = "ReactorCore",
	Anchored = true,
	CanCollide = false,
	Color = Color3.fromRGB(96, 205, 255),
	Material = Enum.Material.Neon,
	Shape = Enum.PartType.Ball,
	Size = Vector3.new(8, 8, 8),
	Position = Vector3.new(0, CONFIG.StationHeight + 5, 0),
	Parent = geometryFolder,
}, {
	create("PointLight", {
		Brightness = 3.5,
		Color = Color3.fromRGB(96, 205, 255),
		Range = 28,
		Shadows = false,
	}),
})

local relayFolder = create("Folder", {
	Name = "Relays",
	Parent = geometryFolder,
})

local launchPadFolder = create("Folder", {
	Name = "LaunchPads",
	Parent = geometryFolder,
})

local bridgeFolder = create("Folder", {
	Name = "Bridges",
	Parent = geometryFolder,
})

local checkpointColor = Color3.fromRGB(138, 182, 255)
local activeRelayColor = Color3.fromRGB(96, 255, 180)
local inactiveRelayColor = Color3.fromRGB(255, 170, 96)

local function makeFlash(position, color)
	local pulse = create("Part", {
		Anchored = true,
		CanCollide = false,
		Color = color,
		Material = Enum.Material.Neon,
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.5, 1.5, 1.5),
		Position = position,
		Parent = effectsFolder,
	})

	local tween = TweenService:Create(pulse, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(8, 8, 8),
		Transparency = 1,
	})

	tween:Play()
	Debris:AddItem(pulse, 0.5)
end

local relayNodes = {}

local RelayNode = {}
RelayNode.__index = RelayNode

function RelayNode.new(index, name, angle)
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local stationPosition = direction * CONFIG.StationRadius + Vector3.new(0, CONFIG.StationHeight, 0)

	local platform = create("Part", {
		Name = name .. "Platform",
		Anchored = true,
		CanCollide = true,
		Color = Color3.fromRGB(34, 44, 60),
		Material = Enum.Material.Metal,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4, 28, 28),
		Orientation = Vector3.new(0, 0, 90),
		Position = stationPosition,
		Parent = relayFolder,
	})

	local trim = create("Part", {
		Name = name .. "Trim",
		Anchored = true,
		CanCollide = false,
		Color = checkpointColor,
		Material = Enum.Material.Neon,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.4, 22, 22),
		Orientation = Vector3.new(0, 0, 90),
		Position = stationPosition + Vector3.new(0, 1.6, 0),
		Parent = relayFolder,
	})

	local checkpoint = create("Part", {
		Name = name .. "Checkpoint",
		Anchored = true,
		CanCollide = false,
		Color = checkpointColor,
		Material = Enum.Material.Neon,
		Size = Vector3.new(12, 1, 12),
		Position = stationPosition + Vector3.new(0, 2.4, 0),
		Parent = relayFolder,
	})

	local pedestal = create("Part", {
		Name = name .. "Pedestal",
		Anchored = true,
		CanCollide = true,
		Color = Color3.fromRGB(22, 28, 40),
		Material = Enum.Material.Metal,
		Size = Vector3.new(6, 8, 6),
		Position = stationPosition + Vector3.new(0, 4, 0),
		Parent = relayFolder,
	})

	local orb = create("Part", {
		Name = name .. "RelayOrb",
		Anchored = true,
		CanCollide = false,
		Color = inactiveRelayColor,
		Material = Enum.Material.Neon,
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(4.5, 4.5, 4.5),
		Position = stationPosition + Vector3.new(0, 9.5, 0),
		Parent = relayFolder,
	}, {
		create("PointLight", {
			Brightness = 2.2,
			Color = inactiveRelayColor,
			Range = 18,
			Shadows = false,
		}),
	})

	local prompt = create("ProximityPrompt", {
		ActionText = "Stabilize Relay",
		RequiresLineOfSight = false,
		HoldDuration = 1.2,
		MaxActivationDistance = 12,
		ObjectText = name .. " Relay",
		Parent = orb,
	})

	local returnPad = create("Part", {
		Name = name .. "ReturnPad",
		Anchored = true,
		CanCollide = false,
		Color = Color3.fromRGB(255, 205, 76),
		Material = Enum.Material.Neon,
		Size = Vector3.new(9, 1, 9),
		Position = stationPosition + Vector3.new(direction.X * -7, 2.1, direction.Z * -7),
		Parent = relayFolder,
	})

	CollectionService:AddTag(checkpoint, "CheckpointPad")
	CollectionService:AddTag(returnPad, "LaunchPad")

	addLabel(orb, name .. " Relay", Vector3.new(0, 4.8, 0), inactiveRelayColor)

	local self = setmetatable({
		Index = index,
		Name = name,
		Angle = angle,
		Direction = direction,
		Platform = platform,
		Orb = orb,
		Prompt = prompt,
		Checkpoint = checkpoint,
		ReturnPad = returnPad,
		StationPosition = stationPosition,
		Active = false,
	}, RelayNode)

	return self
end

function RelayNode:setActive(active)
	self.Active = active
	self.Orb:SetAttribute("Active", active)
	self.Prompt.Enabled = not active

	local targetColor = active and activeRelayColor or inactiveRelayColor
	local targetSize = active and Vector3.new(5.6, 5.6, 5.6) or Vector3.new(4.5, 4.5, 4.5)
	local light = self.Orb:FindFirstChildOfClass("PointLight")

	if light then
		light.Color = targetColor
		light.Brightness = active and 3.5 or 2.2
	end

	TweenService:Create(self.Orb, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = targetColor,
		Size = targetSize,
	}):Play()

	makeFlash(self.Orb.Position, targetColor)
end

function RelayNode:reset()
	self:setActive(false)
end

for index, relayName in ipairs(relayNames) do
	local angle = -math.pi / 2 + (index - 1) * (math.pi / 2)
	local relayNode = RelayNode.new(index, relayName, angle)
	relayNodes[index] = relayNode
	outerStations[relayName] = relayNode
end

for _, relayNode in ipairs(relayNodes) do
	local bridgeLength = CONFIG.StationRadius - CONFIG.BridgeInnerRadius
	local midpointRadius = (CONFIG.StationRadius + CONFIG.BridgeInnerRadius) * 0.5
	local midpoint = relayNode.Direction * midpointRadius + Vector3.new(0, CONFIG.StationHeight, 0)
	local bridgeAngle = math.atan2(relayNode.Direction.Z, relayNode.Direction.X)

	local bridge = create("Part", {
		Name = relayNode.Name .. "Bridge",
		Anchored = true,
		CanCollide = false,
		Color = Color3.fromRGB(80, 214, 255),
		Material = Enum.Material.Glass,
		Size = Vector3.new(bridgeLength, 1.2, 10),
		CFrame = CFrame.new(midpoint + Vector3.new(0, -8, 0)) * CFrame.Angles(0, bridgeAngle, 0),
		Transparency = 0.8,
		Parent = bridgeFolder,
	})

	table.insert(bridgeParts, {
		Part = bridge,
		HomeCFrame = CFrame.new(midpoint) * CFrame.Angles(0, bridgeAngle, 0),
		HiddenCFrame = bridge.CFrame,
	})
end

local function setBridgesEnabled(enabled)
	for _, bridgeData in ipairs(bridgeParts) do
		bridgeData.Part.CanCollide = enabled

		local tween =
			TweenService:Create(bridgeData.Part, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				CFrame = enabled and bridgeData.HomeCFrame or bridgeData.HiddenCFrame,
				Transparency = enabled and 0.2 or 0.8,
			})

		tween:Play()
	end
end

setBridgesEnabled(false)

local launchPads = {}

local function createLaunchPad(name, position, direction, targetPosition, flightTime, color)
	local pad = create("Part", {
		Name = name,
		Anchored = true,
		CanCollide = false,
		Color = color,
		Material = Enum.Material.Neon,
		Size = Vector3.new(10, 1, 10),
		Position = position,
		Parent = launchPadFolder,
	})

	local arrow = create("Part", {
		Name = name .. "Arrow",
		Anchored = true,
		CanCollide = false,
		Color = withAlpha(color, 0.35),
		Material = Enum.Material.Neon,
		Size = Vector3.new(3, 0.4, 8),
		CFrame = CFrame.lookAt(position + Vector3.new(0, 1.2, 0), position + direction * 12 + Vector3.new(0, 1.2, 0)),
		Parent = launchPadFolder,
	})

	CollectionService:AddTag(pad, "LaunchPad")
	addLabel(pad, name:gsub("Pad", ""), Vector3.new(0, 4, 0), color)

	local padData = {
		Part = pad,
		TargetPosition = targetPosition,
		FlightTime = flightTime,
	}

	table.insert(launchPads, padData)
	return padData
end

for _, relayNode in ipairs(relayNodes) do
	createLaunchPad(
		relayNode.Name .. "LaunchPad",
		Vector3.new(relayNode.Direction.X * 12, CONFIG.HubHeight + 2.1, relayNode.Direction.Z * 12),
		relayNode.Direction,
		relayNode.StationPosition + Vector3.new(0, 4, 0),
		CONFIG.LaunchFlightTime,
		Color3.fromRGB(96, 205, 255)
	)
end

local function bindLaunchPad(part, targetPosition, flightTime)
	local touchDebounce = {}

	return part.Touched:Connect(function(hit)
		local player, character, humanoid = getPlayerFromHit(hit)
		if not player or humanoid.Health <= 0 then
			return
		end

		local state = getPlayerState(player)
		local root = getCharacterRoot(character)
		if not root then
			return
		end

		local now = os.clock()
		if touchDebounce[player] and now - touchDebounce[player] < 1 then
			return
		end

		if now - state.LastLaunchTick < 0.65 then
			return
		end

		state.LastLaunchTick = now
		touchDebounce[player] = now

		local launchVelocity = computeBallisticVelocity(root.Position, targetPosition, flightTime)
		root.AssemblyLinearVelocity = launchVelocity
		root:ApplyImpulse(Y_AXIS * root.AssemblyMass * 3)
		makeFlash(part.Position + Vector3.new(0, 1.5, 0), part.Color)
	end)
end

local scriptJanitor = Janitor.new()

for index, relayNode in ipairs(relayNodes) do
	local outwardPad = launchPads[index]
	scriptJanitor:add(bindLaunchPad(outwardPad.Part, outwardPad.TargetPosition, outwardPad.FlightTime))
	scriptJanitor:add(
		bindLaunchPad(relayNode.ReturnPad, hubPad.Position + Vector3.new(0, 5, 0), CONFIG.ReturnFlightTime)
	)
end

local function updateCheckpoint(player, checkpointName, checkpointCFrame)
	local state = getPlayerState(player)
	state.CheckpointCFrame = checkpointCFrame
	state.LastCheckpointName = checkpointName
	player:SetAttribute("CheckpointName", checkpointName)
end

for _, relayNode in ipairs(relayNodes) do
	local perPlayerTouch = {}

	scriptJanitor:add(relayNode.Checkpoint.Touched:Connect(function(hit)
		local player = getPlayerFromHit(hit)
		if not player then
			return
		end

		if perPlayerTouch[player] then
			return
		end

		perPlayerTouch[player] = true
		task.delay(0.75, function()
			perPlayerTouch[player] = nil
		end)

		updateCheckpoint(player, relayNode.Name, relayNode.Platform.CFrame + Vector3.new(0, 6, 0))
		makeFlash(relayNode.Checkpoint.Position + Vector3.new(0, 1, 0), checkpointColor)

		local state = getPlayerState(player)
		if not state.VisitedCheckpoints[relayNode.Name] then
			state.VisitedCheckpoints[relayNode.Name] = true
			awardScore(player, CONFIG.CheckpointScore)
		end
	end))
end

local HazardBeam = {}
HazardBeam.__index = HazardBeam

function HazardBeam.new(name, radius, length, height, phase, speed, color)
	local part = create("Part", {
		Name = name,
		Anchored = true,
		CanCollide = false,
		Color = color,
		Material = Enum.Material.Neon,
		Size = Vector3.new(length, 2.4, 5),
		Transparency = 0.18,
		Parent = geometryFolder,
	})

	CollectionService:AddTag(part, "Hazard")
	part.CollisionGroup = DECOR_GROUP

	return setmetatable({
		Part = part,
		Radius = radius,
		Length = length,
		Height = height,
		Phase = phase,
		Speed = speed,
		BaseSpeed = speed,
		LastQuery = 0,
		HitCooldownByHumanoid = {},
		OverlapParams = OverlapParams.new(),
	}, HazardBeam)
end

function HazardBeam:step(now)
	local angle = self.Phase + now * self.Speed
	local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * self.Radius
	local position = offset + Vector3.new(0, self.Height, 0)
	local facingAngle = math.atan2(offset.Z, offset.X)
	local bob = math.sin(now * 2.2 + self.Phase) * 0.7

	self.Part.CFrame = CFrame.new(position + Vector3.new(0, bob, 0)) * CFrame.Angles(0, facingAngle, 0)

	if now - self.LastQuery < 0.1 then
		return
	end

	self.LastQuery = now
	self.OverlapParams.FilterType = Enum.RaycastFilterType.Exclude
	self.OverlapParams.FilterDescendantsInstances = { world }

	local hits =
		workspace:GetPartBoundsInBox(self.Part.CFrame, self.Part.Size + Vector3.new(2, 4, 2), self.OverlapParams)
	local seenHumanoids = {}

	for _, hit in ipairs(hits) do
		local model = hit:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")

		if humanoid and humanoid.Health > 0 and not seenHumanoids[humanoid] then
			seenHumanoids[humanoid] = true

			local lastHit = self.HitCooldownByHumanoid[humanoid] or 0
			if now - lastHit >= CONFIG.HazardHitCooldown then
				self.HitCooldownByHumanoid[humanoid] = now
				humanoid:TakeDamage(CONFIG.HazardDamage)

				local root = getCharacterRoot(model)
				if root then
					local pushDirection =
						Vector3.new(root.Position.X - self.Part.Position.X, 0, root.Position.Z - self.Part.Position.Z)
					if pushDirection.Magnitude < 0.001 then
						pushDirection = self.Part.CFrame.RightVector
					end

					root:ApplyImpulse((pushDirection.Unit + Vector3.new(0, 0.35, 0)) * root.AssemblyMass * 48)
				end
			end
		end
	end
end

function HazardBeam:setStable(enabled)
	self.Speed = enabled and self.BaseSpeed * 0.45 or self.BaseSpeed
	TweenService:Create(self.Part, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = enabled and Color3.fromRGB(120, 255, 200) or Color3.fromRGB(255, 96, 96),
		Transparency = enabled and 0.35 or 0.18,
	}):Play()
end

table.insert(
	hazardBeams,
	HazardBeam.new("InnerHazard", 34, 54, CONFIG.StationHeight + 1.5, 0, 1.4, Color3.fromRGB(255, 96, 96))
)
table.insert(
	hazardBeams,
	HazardBeam.new("OuterHazard", 46, 70, CONFIG.StationHeight + 8, math.pi / 2, -1.1, Color3.fromRGB(255, 120, 80))
)

local Drone = {}
Drone.__index = Drone

function Drone.new(index, radius, height, angularSpeed, phase)
	local model = create("Model", {
		Name = "Drone" .. index,
		Parent = geometryFolder,
	})

	local body = create("Part", {
		Name = "Body",
		Anchored = true,
		CanCollide = false,
		Color = Color3.fromRGB(150, 234, 255),
		Material = Enum.Material.Neon,
		Size = Vector3.new(3, 1.3, 3),
		Parent = model,
	})

	local wingLeft = create("Part", {
		Name = "WingLeft",
		Anchored = true,
		CanCollide = false,
		Color = Color3.fromRGB(40, 48, 62),
		Material = Enum.Material.Metal,
		Size = Vector3.new(6, 0.4, 1.4),
		Parent = model,
	})

	local wingRight = wingLeft:Clone()
	wingRight.Name = "WingRight"
	wingRight.Parent = model

	local attachment0 = create("Attachment", {
		Position = Vector3.new(-1.4, 0, 0),
		Parent = body,
	})

	local attachment1 = create("Attachment", {
		Position = Vector3.new(1.4, 0, 0),
		Parent = body,
	})

	create("Trail", {
		Attachment0 = attachment0,
		Attachment1 = attachment1,
		Color = ColorSequence.new(Color3.fromRGB(96, 205, 255), Color3.fromRGB(255, 255, 255)),
		Enabled = true,
		FaceCamera = true,
		Lifetime = 0.25,
		LightEmission = 1,
		MinLength = 0.05,
		Transparency = NumberSequence.new(0.1, 1),
		Parent = body,
	})

	setCollisionGroupRecursive(model, DECOR_GROUP)

	return setmetatable({
		Model = model,
		Body = body,
		WingLeft = wingLeft,
		WingRight = wingRight,
		Radius = radius,
		Height = height,
		AngularSpeed = angularSpeed,
		Phase = phase,
	}, Drone)
end

function Drone:step(now)
	local angle = self.Phase + now * self.AngularSpeed
	local position = Vector3.new(math.cos(angle), 0, math.sin(angle)) * self.Radius + Vector3.new(0, self.Height, 0)
	local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
	local pivot = CFrame.lookAt(position, position + tangent, Y_AXIS)
	local wingOffset = math.sin(now * 12 + self.Phase) * 0.2

	self.Model:PivotTo(pivot)
	self.WingLeft.CFrame = pivot * CFrame.new(0, wingOffset, -1.4)
	self.WingRight.CFrame = pivot * CFrame.new(0, -wingOffset, 1.4)
end

for index = 1, 6 do
	table.insert(
		movingDrones,
		Drone.new(
			index,
			54 + index * 2,
			CONFIG.StationHeight + 10 + index % 2,
			0.85 + index * 0.05,
			index * math.pi / 3
		)
	)
end

local function setCorePadEnabled(enabled)
	coreRewardPad.CanCollide = enabled
	coreRewardPad.Transparency = enabled and 0.18 or 0.55
	coreRewardPad.Color = enabled and Color3.fromRGB(120, 255, 200) or Color3.fromRGB(255, 205, 76)
end

setCorePadEnabled(false)

local function resetRelays()
	gameState.ActiveNodeCount = 0

	for _, relayNode in ipairs(relayNodes) do
		relayNode:reset()
	end
end

local function enterStableWindow()
	if gameState.IsStable then
		return
	end

	gameState.IsStable = true
	gameState.CycleNumber += 1
	gameState.StableEndsAt = os.clock() + CONFIG.StableDuration

	reactorCore.Color = Color3.fromRGB(120, 255, 200)
	reactorCore.PointLight.Color = reactorCore.Color
	reactorCore.PointLight.Brightness = 4.4

	for _, beam in ipairs(hazardBeams) do
		beam:setStable(true)
	end

	setBridgesEnabled(true)
	setCorePadEnabled(true)

	for _, player in ipairs(Players:GetPlayers()) do
		awardScore(player, CONFIG.StabilizationBonus)
		awardStat(player, "Stabilizations", 1)

		local state = getPlayerState(player)
		state.NextSurvivalTick = os.clock() + CONFIG.SurvivalTickSeconds
	end

	task.delay(CONFIG.StableDuration, function()
		if not gameState.IsStable or os.clock() < gameState.StableEndsAt then
			return
		end

		gameState.IsStable = false
		reactorCore.Color = Color3.fromRGB(96, 205, 255)
		reactorCore.PointLight.Color = reactorCore.Color
		reactorCore.PointLight.Brightness = 3.5

		for _, beam in ipairs(hazardBeams) do
			beam:setStable(false)
		end

		setBridgesEnabled(false)
		setCorePadEnabled(false)
		resetRelays()
	end)
end

for _, relayNode in ipairs(relayNodes) do
	scriptJanitor:add(relayNode.Prompt.Triggered:Connect(function(player)
		local state = getPlayerState(player)
		if relayNode.Active then
			return
		end

		relayNode:setActive(true)
		gameState.ActiveNodeCount += 1

		updateCheckpoint(player, relayNode.Name, relayNode.Platform.CFrame + Vector3.new(0, 6, 0))
		awardScore(player, CONFIG.NodeScore)
		awardStat(player, "Nodes", 1)
		state.NextSurvivalTick = os.clock() + CONFIG.SurvivalTickSeconds

		if gameState.ActiveNodeCount >= #relayNodes then
			enterStableWindow()
		end
	end))
end

local claimedThisTouch = {}
scriptJanitor:add(coreRewardPad.Touched:Connect(function(hit)
	local player, _, humanoid = getPlayerFromHit(hit)
	if not player or humanoid.Health <= 0 or not gameState.IsStable then
		return
	end

	if claimedThisTouch[player] then
		return
	end

	local state = getPlayerState(player)
	if state.ClaimedCoreCycle == gameState.CycleNumber then
		return
	end

	claimedThisTouch[player] = true
	task.delay(0.75, function()
		claimedThisTouch[player] = nil
	end)

	state.ClaimedCoreCycle = gameState.CycleNumber
	awardScore(player, CONFIG.CoreScore)
	awardStat(player, "CoreClaims", 1)
	makeFlash(coreRewardPad.Position + Vector3.new(0, 1.5, 0), coreRewardPad.Color)
end))

local function createLeaderstats(player)
	local leaderstats = create("Folder", {
		Name = "leaderstats",
		Parent = player,
	})

	create("IntValue", {
		Name = "Score",
		Value = 0,
		Parent = leaderstats,
	})

	create("IntValue", {
		Name = "Nodes",
		Value = 0,
		Parent = leaderstats,
	})

	create("IntValue", {
		Name = "Stabilizations",
		Value = 0,
		Parent = leaderstats,
	})

	create("IntValue", {
		Name = "CoreClaims",
		Value = 0,
		Parent = leaderstats,
	})
end

local function respawnPlayer(player)
	local state = getPlayerState(player)
	if state.PendingRespawn then
		return
	end

	state.PendingRespawn = true
	task.delay(0.15, function()
		if player.Parent then
			player:LoadCharacter()
		end
		state.PendingRespawn = false
	end)
end

local function onCharacterAdded(player, character)
	local state = getPlayerState(player)
	local humanoid = character:WaitForChild("Humanoid")
	local root = character:WaitForChild("HumanoidRootPart")

	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 8

	task.defer(function()
		if character.Parent then
			character:PivotTo(state.CheckpointCFrame)
		end
	end)

	scriptJanitor:add(humanoid.Died:Connect(function()
		task.delay(1.25, function()
			if player.Parent then
				respawnPlayer(player)
			end
		end)
	end))

	create("Highlight", {
		Adornee = character,
		DepthMode = Enum.HighlightDepthMode.Occluded,
		Enabled = true,
		FillColor = Color3.fromRGB(96, 205, 255),
		FillTransparency = 0.88,
		OutlineColor = Color3.fromRGB(255, 255, 255),
		OutlineTransparency = 0.35,
		Parent = character,
	})

	root:SetAttribute("SpawnCheckpoint", state.LastCheckpointName)
end

local function onPlayerAdded(player)
	createLeaderstats(player)
	player:SetAttribute("CheckpointName", "Hub")
	updateCheckpoint(player, "Hub", CFrame.new(0, CONFIG.HubHeight + 5, 0))

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player)
	playerStateByUserId[player.UserId] = nil
end

for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

scriptJanitor:add(Players.PlayerAdded:Connect(onPlayerAdded))
scriptJanitor:add(Players.PlayerRemoving:Connect(onPlayerRemoving))

RunService.Heartbeat:Connect(function()
	local now = os.clock()

	for _, beam in ipairs(hazardBeams) do
		beam:step(now)
	end

	for _, drone in ipairs(movingDrones) do
		drone:step(now)
	end

	reactorCore.CFrame = CFrame.new(reactorCore.Position) * CFrame.Angles(0, now * 1.2, 0)
	hubTrim.CFrame = CFrame.new(hubTrim.Position) * CFrame.Angles(0, -now * 0.6, 0) * CFrame.Angles(0, 0, math.rad(90))

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = getCharacterRoot(character)

		if humanoid and root and humanoid.Health > 0 then
			if root.Position.Y < CONFIG.RespawnFloorY then
				respawnPlayer(player)
			end

			if gameState.IsStable then
				local state = getPlayerState(player)
				if now >= state.NextSurvivalTick then
					state.NextSurvivalTick = now + CONFIG.SurvivalTickSeconds
					awardScore(player, CONFIG.SurvivalTickScore)
				end
			end
		end
	end
end)
