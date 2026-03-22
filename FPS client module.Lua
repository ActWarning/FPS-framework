-- Client weapon framework
-- This module handles the local weapon viewmodel:
-- animations, ammo gui, simple effects and camera sway

local Framework = {}

-- Public references
-- Viewmodel is the cloned first person model inside the camera
-- Module is an optional per-weapon framework module
Framework.Viewmodel = nil
Framework.Module = nil

-- Animation/state data
Framework._tracks = {}
Framework._current_state = nil
Framework._move_held = false

-- Action flags
-- These are used to know if a one-shot animation is active right now
Framework._equip_playing = false
Framework._shoot_playing = false
Framework._reload_playing = false
Framework._inspect_playing = false
Framework._weapon_locked = false

-- Track connections
-- Each one-shot track listens for .Stopped so we can restore idle/move state
Framework._equip_conn = nil
Framework._shoot_conn = nil
Framework._reload_conn = nil
Framework._inspect_conn = nil

-- Action token
-- Every time a new action starts or an old one gets cancelled,
-- this value changes. Old callbacks compare their saved token with
-- the current one so outdated .Stopped events do not restore the wrong state.
Framework._action_token = 0

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- Sway state
-- _last_camera_cframe is used to measure camera movement between frames
-- _sway_rot and _sway_pos are smoothly blended over time
Framework._last_camera_cframe = nil
Framework._sway_rot = CFrame.new()
Framework._sway_pos = Vector3.new()

Framework.Sway = {
	Enabled = true,

	RotMultiplier = 1.15,
	PosMultiplier = 0.10,

	MaxRot = math.rad(8),
	MaxPos = 0.22,

	ReturnSpeed = 14,
	FollowSpeed = 22,
}

local Default_Fade = 0.12

-- Gui helpers

-- Returns the ammo TextLabel from the current viewmodel if it exists.
-- Some weapons may not have this gui, so every step is checked safely.
local function get_ammo_label(viewmodel: Model?)
	if not viewmodel then
		return nil
	end

	local Ammo_Part = viewmodel:FindFirstChild("AmmoPart")
	if not Ammo_Part then
		return nil
	end

	local Surface_Gui = Ammo_Part:FindFirstChild("SurfaceGui")
	if not Surface_Gui then
		return nil
	end

	local Frame = Surface_Gui:FindFirstChild("Frame")
	if not Frame then
		return nil
	end

	return Frame:FindFirstChild("TextLabel")
end

-- Returns the ammo gui frame that gets tweened in and out.
local function get_ammo_frame(viewmodel: Model?)
	if not viewmodel then
		return nil
	end

	local Ammo_Part = viewmodel:FindFirstChild("AmmoPart")
	if not Ammo_Part then
		return nil
	end

	local Surface_Gui = Ammo_Part:FindFirstChild("SurfaceGui")
	if not Surface_Gui then
		return nil
	end

	return Surface_Gui:FindFirstChild("Frame")
end

-- Updates the ammo text shown on the weapon model.
-- Right now this gui only displays current mag / max mag.
local function update_ammo_gui(viewmodel: Model?, ammo, maxammo)
	local Text_Label = get_ammo_label(viewmodel)
	if not Text_Label then
		return
	end

	Text_Label.Text = tostring(ammo) .. "/" .. tostring(maxammo)
end

-- Shows or hides the ammo frame with a size tween.
-- When hiding, the frame is made invisible after the tween finishes
-- so the closing animation can still be seen.
local function set_ammo_gui_visible(viewmodel: Model?, isvisible: boolean)
	local Ammo_Frame = get_ammo_frame(viewmodel)
	if not Ammo_Frame then
		return
	end

	if isvisible then
		Ammo_Frame.Visible = true
		TweenService:Create(Ammo_Frame, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(1, 0, 1, 0)
		}):Play()
	else
		Ammo_Frame.Size = UDim2.new(1, 0, 1, 0)

		TweenService:Create(Ammo_Frame, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = UDim2.new(0, 0, 1, 0)
		}):Play()

		task.spawn(function()
			task.wait(0.5)

			if not Ammo_Frame or not Ammo_Frame.Parent then
				return
			end

			Ammo_Frame.Size = UDim2.new(0, 0, 1, 0)
			Ammo_Frame.Visible = false
		end)
	end
end

function Framework.SetAmmo(ammo, maxammo, reserve, maxreserve)
	if not Framework.Viewmodel then
		return
	end

	-- reserve and maxreserve are kept in the signature so the outside api
	-- does not break even if this specific gui only shows mag ammo
	update_ammo_gui(Framework.Viewmodel, ammo, maxammo)
	set_ammo_gui_visible(Framework.Viewmodel, true)
end

function Framework.SetAmmoVisible(isvisible: boolean)
	if not Framework.Viewmodel then
		return
	end

	set_ammo_gui_visible(Framework.Viewmodel, isvisible)
end

-- Animation helpers

-- Gets the AnimationController from the current viewmodel.
local function get_animation_controller(viewmodel: Model?): AnimationController?
	if not viewmodel then
		return nil
	end

	return viewmodel:FindFirstChild("AnimationController")
end

-- Gets the Animator that is responsible for loading and playing tracks.
-- If it does not exist yet, it is created once and reused.
local function get_animator(viewmodel: Model?): Animator?
	local Controller = get_animation_controller(viewmodel)
	if not Controller then
		return nil
	end

	local Animator_Object = Controller:FindFirstChildOfClass("Animator")
	if Animator_Object then
		return Animator_Object
	end

	Animator_Object = Instance.new("Animator")
	Animator_Object.Parent = Controller

	return Animator_Object
end

-- Creates an AnimationTrack from a given animation object.
-- Returns nil if either the viewmodel or animation is missing.
local function load_track(viewmodel: Model?, animation: Animation?): AnimationTrack?
	if not viewmodel or not animation then
		return nil
	end

	local Animator_Object = get_animator(viewmodel)
	if not Animator_Object then
		return nil
	end

	return Animator_Object:LoadAnimation(animation)
end

-- Stops every currently playing track except the one we just started.
-- This keeps the weapon from blending multiple conflicting tracks at once.
local function stop_all_except(excepttrack: AnimationTrack?, fadetime: number?)
	local Animator_Object = get_animator(Framework.Viewmodel)
	if not Animator_Object then
		return
	end

	for _, Track in ipairs(Animator_Object:GetPlayingAnimationTracks()) do
		if Track ~= excepttrack then
			Track:Stop(fadetime or Default_Fade)
		end
	end
end

-- Plays a track with optional fade and speed,
-- then stops all other tracks so this one fully takes control.
function Framework._PlayTrack(track: AnimationTrack?, fadetime: number?, speed: number?)
	if not track then
		return
	end

	fadetime = fadetime or Default_Fade

	if speed then
		track:AdjustSpeed(speed)
	end

	track:Play(fadetime)
	stop_all_except(track, fadetime)
end

-- Reads humanoid movement and chooses the best matching movement animation.
-- The direction is calculated relative to the camera so forward/back/left/right
-- still match what the player feels in first person.
local function apply_move_from_humanoid(): boolean
	local Player = Players.LocalPlayer
	local Camera = workspace.CurrentCamera
	local Character = Player.Character
	if not Character or not Camera then
		return false
	end

	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	if not Humanoid then
		return false
	end

	local Move_Direction = Humanoid.MoveDirection
	if Move_Direction.Magnitude < 0.05 then
		return false
	end

	local Local_Direction = Camera.CFrame:VectorToObjectSpace(Move_Direction)

	local Direction: string
	if math.abs(Local_Direction.Z) >= math.abs(Local_Direction.X) then
		Direction = (Local_Direction.Z < 0) and "Forward" or "Backward"
	else
		Direction = (Local_Direction.X > 0) and "Right" or "Left"
	end

	Framework._current_state = "Move:" .. Direction
	Framework._PlayTrack(Framework._tracks.Move and Framework._tracks.Move[Direction], Default_Fade)
	return true
end

-- Increments the action token and returns the new value.
-- Used when starting a fresh action so older callbacks become invalid.
local function next_action_token(): number
	Framework._action_token += 1
	return Framework._action_token
end

-- Checks whether a callback still belongs to the most recent action.
local function is_action_token_valid(token: number): boolean
	return token == Framework._action_token
end

-- Returns the weapon to its base animation after a one-shot action ends.
-- If movement is still held, it tries to restore the correct movement track.
-- Otherwise it falls back to idle.
local function restore_base_animation(token: number)
	if not is_action_token_valid(token) then
		return
	end

	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		return
	end

	if Framework._move_held then
		if not apply_move_from_humanoid() then
			Framework.Idle()
		end
	else
		Framework.Idle()
	end
end

-- Builds every animation track used by the current weapon.
-- The expected structure is:
-- Animations
--   Idle
--   Equip
--   Movement
--     Forward / Backward / Left / Right
--   Gun
--     Shoot / Reload / Inspect
function Framework._BuildTracks()
	if not Framework.Viewmodel then
		return
	end

	Framework._tracks = {}

	local Animation_Folder = Framework.Viewmodel:FindFirstChild("Animations")
	if not Animation_Folder then
		return
	end

	local Gun_Animation_Folder = Animation_Folder:FindFirstChild("Gun")

	if Animation_Folder:FindFirstChild("Idle") then
		Framework._tracks.Idle = load_track(Framework.Viewmodel, Animation_Folder.Idle)
		if Framework._tracks.Idle then
			Framework._tracks.Idle.Priority = Enum.AnimationPriority.Idle
			Framework._tracks.Idle.Looped = true
		end
	end

	if Animation_Folder:FindFirstChild("Equip") then
		Framework._tracks.Equip = load_track(Framework.Viewmodel, Animation_Folder.Equip)
		if Framework._tracks.Equip then
			Framework._tracks.Equip.Priority = Enum.AnimationPriority.Action
			Framework._tracks.Equip.Looped = false
		end
	end

	if Gun_Animation_Folder then
		if Gun_Animation_Folder:FindFirstChild("Inspect") then
			Framework._tracks.Inspect = load_track(Framework.Viewmodel, Gun_Animation_Folder.Inspect)
			if Framework._tracks.Inspect then
				Framework._tracks.Inspect.Priority = Enum.AnimationPriority.Action
				Framework._tracks.Inspect.Looped = false
			end
		end

		if Gun_Animation_Folder:FindFirstChild("Shoot") then
			Framework._tracks.Shoot = load_track(Framework.Viewmodel, Gun_Animation_Folder.Shoot)
			if Framework._tracks.Shoot then
				Framework._tracks.Shoot.Priority = Enum.AnimationPriority.Action
				Framework._tracks.Shoot.Looped = false
			end
		end

		if Gun_Animation_Folder:FindFirstChild("Reload") then
			Framework._tracks.Reload = load_track(Framework.Viewmodel, Gun_Animation_Folder.Reload)
			if Framework._tracks.Reload then
				Framework._tracks.Reload.Priority = Enum.AnimationPriority.Action
				Framework._tracks.Reload.Looped = false
			end
		end
	end

	Framework._tracks.Move = {}

	local Move_Folder = Animation_Folder:FindFirstChild("Movement")
	if Move_Folder then
		for _, Direction_Name in ipairs({"Forward", "Backward", "Left", "Right"}) do
			if Move_Folder:FindFirstChild(Direction_Name) then
				local Track = load_track(Framework.Viewmodel, Move_Folder[Direction_Name])
				if Track then
					Track.Priority = Enum.AnimationPriority.Movement
					Track.Looped = true
					Framework._tracks.Move[Direction_Name] = Track
				end
			end
		end
	end
end

-- Preloads all Animation instances found in the weapon viewmodel.
-- This reduces the chance of a visible delay on first use.
function Framework.PreloadAnimations(item: string)
	local Viewmodel_Folder = ReplicatedStorage:FindFirstChild("Models")
		and ReplicatedStorage.Models:FindFirstChild("Viewmodels")

	if not Viewmodel_Folder then
		return
	end

	local Viewmodel = Viewmodel_Folder:FindFirstChild(item)
	if not Viewmodel then
		return
	end

	local Animation_Folder = Viewmodel:FindFirstChild("Animations")
	if not Animation_Folder then
		return
	end

	local Assets = {}
	for _, Instance_Item in ipairs(Animation_Folder:GetDescendants()) do
		if Instance_Item:IsA("Animation") then
			table.insert(Assets, Instance_Item)
		end
	end

	if #Assets > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(Assets)
		end)
	end
end

-- Public helpers

-- Returns the gun frame part if present.
-- Falls back to the gun model itself when needed.
function Framework.GetGunFrame(): Instance?
	if not Framework.Viewmodel then
		return nil
	end

	local Gun = Framework.Viewmodel:FindFirstChild("Gun")
	if not Gun then
		return nil
	end

	return Gun:FindFirstChild("Frame") or Gun
end

-- Returns the barrel attachment used for muzzle flash effects.
function Framework.GetBarrelAttachment(): Attachment?
	if not Framework.Viewmodel then
		return nil
	end

	local Gun = Framework.Viewmodel:FindFirstChild("Gun")
	if not Gun then
		return nil
	end

	local Barrel = Gun:FindFirstChild("Barrel")
	if not Barrel then
		return nil
	end

	return Barrel:FindFirstChildWhichIsA("Attachment")
end

-- Clones and plays a sound from the weapon SFX folder.
-- Optional settings let the caller override volume, speed and lifetime.
function Framework.PlaySfx(sfxname: string, parent: Instance?, settings: {Volume: number?, PlaybackSpeed: number?, TimePosition: number?, Lifetime: number?}?)
	if not Framework.Viewmodel then
		return
	end

	local Sfx_Folder = Framework.Viewmodel:FindFirstChild("SFX")
	if not Sfx_Folder then
		return
	end

	local Template = Sfx_Folder:FindFirstChild(sfxname)
	if not Template or not Template:IsA("Sound") then
		return
	end

	local Sound = Template:Clone()
	Sound.Parent = parent or Framework.Viewmodel

	if settings then
		if settings.Volume ~= nil then
			Sound.Volume = settings.Volume
		end

		if settings.PlaybackSpeed ~= nil then
			Sound.PlaybackSpeed = settings.PlaybackSpeed
		end

		if settings.TimePosition ~= nil then
			Sound.TimePosition = settings.TimePosition
		end
	end

	Sound:Play()
	Debris:AddItem(Sound, (settings and settings.Lifetime) or 6)
end

-- Emits muzzle particles and briefly enables the light on the barrel attachment.
function Framework.PlayMuzzleFlash()
	local Attachment = Framework.GetBarrelAttachment()
	if not Attachment then
		return
	end

	for _, Instance_Item in ipairs(Attachment:GetChildren()) do
		if Instance_Item:IsA("ParticleEmitter") then
			Instance_Item:Emit(1)
		end
	end

	local Flash_Light = Attachment:FindFirstChildWhichIsA("PointLight")
	if Flash_Light then
		Flash_Light.Enabled = true

		local Old_Brightness = Flash_Light.Brightness
		Flash_Light.Brightness = Old_Brightness * (0.85 + math.random() * 0.3)

		task.delay(0.06, function()
			if Flash_Light and Flash_Light.Parent then
				Flash_Light.Enabled = false
				Flash_Light.Brightness = Old_Brightness
			end
		end)
	end
end

-- Clears the current weapon slot and resets all local state.
-- This disconnects old animation callbacks, destroys old camera models
-- and resets sway/action data so the next weapon starts cleanly.
function Framework.ClearSlot()
	local Camera = workspace.CurrentCamera
	if Camera then
		for _, Child in pairs(Camera:GetChildren()) do
			if Child:IsA("Model") then
				Child:Destroy()
			end
		end
	end

	if Framework._equip_conn then
		Framework._equip_conn:Disconnect()
		Framework._equip_conn = nil
	end

	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
		Framework._inspect_conn = nil
	end

	if Framework._shoot_conn then
		Framework._shoot_conn:Disconnect()
		Framework._shoot_conn = nil
	end

	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
		Framework._reload_conn = nil
	end

	Framework._equip_playing = false
	Framework._inspect_playing = false
	Framework._shoot_playing = false
	Framework._reload_playing = false
	Framework._weapon_locked = false

	Framework._action_token = 0

	Framework.Viewmodel = nil
	Framework.Module = nil
	Framework._tracks = {}
	Framework._current_state = nil
	Framework._move_held = false

	Framework._last_camera_cframe = nil
	Framework._sway_rot = CFrame.new()
	Framework._sway_pos = Vector3.new()
end

-- Plays the idle animation when no other action is active.
function Framework.Idle()
	Framework._move_held = false

	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		return
	end

	if Framework._current_state == "Idle" then
		return
	end

	Framework._current_state = "Idle"
	Framework._PlayTrack(Framework._tracks.Idle, Default_Fade)
end

-- Starts a movement animation from keyboard input.
-- This is mainly used as a quick local state switch,
-- while restore_base_animation can also re-evaluate movement from Humanoid.
function Framework.Movement(key: Enum.KeyCode)
	Framework._move_held = true

	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		return
	end

	local Direction: string? = nil

	if key == Enum.KeyCode.W then
		Direction = "Forward"
	elseif key == Enum.KeyCode.S then
		Direction = "Backward"
	elseif key == Enum.KeyCode.D then
		Direction = "Right"
	elseif key == Enum.KeyCode.A then
		Direction = "Left"
	end

	if not Direction then
		return
	end

	Framework._current_state = "Move:" .. Direction
	Framework._PlayTrack(Framework._tracks.Move and Framework._tracks.Move[Direction], Default_Fade)
end

-- Plays the inspect animation if the weapon is free.
-- Ammo gui is hidden during inspect and restored when the action ends.
function Framework.Inspect()
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing or Framework._inspect_playing then
		return
	end

	if not Framework._tracks.Inspect then
		return
	end

	local Action_Token = next_action_token()

	Framework._inspect_playing = true
	Framework._weapon_locked = true

	Framework._current_state = "Inspect"
	Framework._PlayTrack(Framework._tracks.Inspect, Default_Fade)

	if Framework.Module and Framework.Module.ClientInspect then
		Framework.Module.ClientInspect(Framework)
	end

	set_ammo_gui_visible(Framework.Viewmodel, false)

	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
	end

	Framework._inspect_conn = Framework._tracks.Inspect.Stopped:Connect(function()
		Framework._inspect_playing = false

		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		set_ammo_gui_visible(Framework.Viewmodel, true)
		restore_base_animation(Action_Token)
	end)
end

-- Cancels the inspect state immediately.
-- The token is advanced first so any late callback from the old track is ignored.
function Framework.CancelInspect()
	if not Framework._inspect_playing then
		return
	end

	next_action_token()

	Framework._inspect_playing = false
	Framework._weapon_locked = false
	set_ammo_gui_visible(Framework.Viewmodel, true)

	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
		Framework._inspect_conn = nil
	end

	if Framework._tracks.Inspect then
		pcall(function()
			Framework._tracks.Inspect:Stop(0)
		end)
	end

	if Framework.Module and Framework.Module.ClientCancelInspect then
		Framework.Module.ClientCancelInspect(Framework)
	end

	restore_base_animation(Framework._action_token)
end

-- Plays the shoot animation and restores the base state after it ends.
function Framework.Shoot()
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing then
		return
	end

	if not Framework._tracks.Shoot then
		return
	end

	local Action_Token = next_action_token()

	Framework._weapon_locked = true
	Framework._shoot_playing = true

	Framework._current_state = "Shoot"
	Framework._PlayTrack(Framework._tracks.Shoot, Default_Fade)

	if Framework.Module and Framework.Module.ClientShoot then
		Framework.Module.ClientShoot(Framework)
	end

	if Framework._shoot_conn then
		Framework._shoot_conn:Disconnect()
	end

	Framework._shoot_conn = Framework._tracks.Shoot.Stopped:Connect(function()
		Framework._shoot_playing = false

		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		restore_base_animation(Action_Token)
	end)
end

-- Plays the reload animation, hides the ammo gui while reloading
-- and restores everything when the animation finishes.
function Framework.Reload()
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing then
		return
	end

	if not Framework._tracks.Reload then
		return
	end

	local Action_Token = next_action_token()

	Framework._weapon_locked = true
	Framework._reload_playing = true

	Framework._current_state = "Reload"
	Framework._PlayTrack(Framework._tracks.Reload, Default_Fade)
	set_ammo_gui_visible(Framework.Viewmodel, false)

	if Framework.Module and Framework.Module.ClientReload then
		Framework.Module.ClientReload(Framework)
	end

	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
	end

	Framework._reload_conn = Framework._tracks.Reload.Stopped:Connect(function()
		Framework._reload_playing = false

		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		set_ammo_gui_visible(Framework.Viewmodel, true)
		restore_base_animation(Action_Token)
	end)
end

-- Stops reload immediately and returns to a normal base state.
function Framework.CancelReload()
	if not Framework._reload_playing then
		return
	end

	next_action_token()

	Framework._reload_playing = false
	Framework._weapon_locked = false

	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
		Framework._reload_conn = nil
	end

	if Framework._tracks.Reload then
		pcall(function()
			Framework._tracks.Reload:Stop(0)
		end)
	end

	if Framework.Module and Framework.Module.ClientCancelReload then
		Framework.Module.ClientCancelReload(Framework)
	end

	set_ammo_gui_visible(Framework.Viewmodel, true)
	restore_base_animation(Framework._action_token)
end

-- Plays a dry fire action.
-- If the weapon has a custom handler, it is used first.
function Framework.Dry()
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing then
		return
	end

	if Framework.Module and Framework.Module.ClientDry then
		Framework.Module.ClientDry(Framework)
		return
	end

	Framework.PlaySfx("DryClick", Framework.GetGunFrame() or Framework.Viewmodel, {Lifetime = 4})
end

-- World shot fx

-- Creates a very simple tracer between origin and endpos.
-- The part is short-lived and only used as a quick visual effect.
local function render_tracer(origin: Vector3, endpos: Vector3)
	local Delta = endpos - origin
	local Distance = Delta.Magnitude
	if Distance < 0.2 then
		return
	end

	if Distance > 1500 then
		endpos = origin + Delta.Unit * 1500
		Delta = endpos - origin
		Distance = Delta.Magnitude
	end

	local Midpoint = origin + Delta * 0.5

	local Tracer = Instance.new("Part")
	Tracer.Name = "Tracer"
	Tracer.Anchored = true
	Tracer.CanCollide = false
	Tracer.CanQuery = false
	Tracer.CanTouch = false
	Tracer.Material = Enum.Material.Neon
	Tracer.Transparency = 0.15
	Tracer.Size = Vector3.new(0.04, 0.04, Distance)
	Tracer.CFrame = CFrame.lookAt(Midpoint, endpos)
	Tracer.Parent = workspace

	Debris:AddItem(Tracer, 0.05)
end

-- Creates a short impact light at the hit position.
local function render_impact(endpos: Vector3)
	local Part = Instance.new("Part")
	Part.Anchored = true
	Part.CanCollide = false
	Part.CanQuery = false
	Part.CanTouch = false
	Part.Transparency = 1
	Part.Size = Vector3.new(0.2, 0.2, 0.2)
	Part.CFrame = CFrame.new(endpos)
	Part.Parent = workspace

	local Light = Instance.new("PointLight")
	Light.Brightness = 2
	Light.Range = 6
	Light.Parent = Part

	Debris:AddItem(Part, 0.08)
end

-- Renders simple replicated shot effects in the world.
function Framework.RenderShotFX(shooterplayer: Player, weaponname: string, origin: Vector3, dir: Vector3, endpos: Vector3, hit: any)
	if typeof(origin) == "Vector3" and typeof(endpos) == "Vector3" then
		render_tracer(origin, endpos)
	end

	if hit == true then
		render_impact(endpos)
	end
end

-- Viewmodel sway

-- Applies camera-based sway to the weapon camera part.
-- The viewmodel follows camera movement with a small delay so it feels less rigid.
-- Rotation and position are clamped to avoid extreme offsets on fast movement.
function Framework.StepViewmodel(cameracframe: CFrame, dt: number)
	if not Framework.Viewmodel then
		Framework._last_camera_cframe = cameracframe
		return
	end

	local Camera_Part = Framework.Viewmodel:FindFirstChild("Camera")
	if not Camera_Part or not Camera_Part:IsA("BasePart") then
		Framework._last_camera_cframe = cameracframe
		return
	end

	if not Framework.Sway.Enabled then
		Camera_Part.CFrame = cameracframe
		Framework._last_camera_cframe = cameracframe
		return
	end

	if not Framework._last_camera_cframe then
		Framework._last_camera_cframe = cameracframe
		Camera_Part.CFrame = cameracframe
		return
	end

	local Delta = Framework._last_camera_cframe:ToObjectSpace(cameracframe)
	local Pitch, Yaw, Roll = Delta:ToOrientation()

	local Target_Rot_X = math.clamp(-Pitch * Framework.Sway.RotMultiplier, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)
	local Target_Rot_Y = math.clamp(-Yaw * Framework.Sway.RotMultiplier, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)
	local Target_Roll = math.clamp(-Roll * 0.25, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)

	local Target_Rotation = CFrame.Angles(Target_Rot_X, Target_Rot_Y, Target_Roll)

	local Target_Position = Vector3.new(
		math.clamp(-Yaw * Framework.Sway.PosMultiplier, -Framework.Sway.MaxPos, Framework.Sway.MaxPos),
		math.clamp(-Pitch * Framework.Sway.PosMultiplier, -Framework.Sway.MaxPos, Framework.Sway.MaxPos),
		0
	)

	local Follow_Alpha = 1 - math.exp(-dt * Framework.Sway.FollowSpeed)
	local Return_Alpha = 1 - math.exp(-dt * Framework.Sway.ReturnSpeed)

	Framework._sway_pos = Framework._sway_pos:Lerp(Target_Position, Follow_Alpha)
	Framework._sway_rot = Framework._sway_rot:Lerp(Target_Rotation, Return_Alpha)

	Camera_Part.CFrame = cameracframe * CFrame.new(Framework._sway_pos) * Framework._sway_rot
	Framework._last_camera_cframe = cameracframe
end

-- Loads a weapon into the current slot.
-- This clears the old viewmodel, clones the new one into the camera,
-- syncs arm colors, builds all tracks and starts equip or idle state.
function Framework.LoadSlot(item: string)
	Framework.ClearSlot()

	local Player = Players.LocalPlayer
	local Character = Player.Character
	local Camera = workspace.CurrentCamera

	if not Character or not Camera then
		return
	end

	local Viewmodel_Folder = ReplicatedStorage.Models.Viewmodels
	local Modules = ReplicatedStorage.Modules.Framework

	if Modules:FindFirstChild(item) then
		Framework.Module = require(Modules[item])
	else
		Framework.Module = nil
	end

	if Viewmodel_Folder:FindFirstChild(item) then
		Framework.Viewmodel = Viewmodel_Folder[item]:Clone()
		Framework.Viewmodel.Parent = Camera
	else
		return
	end

	-- Sync first person arm colors with the player's current character
	if Framework.Viewmodel:FindFirstChild("RightArm") and Character:FindFirstChild("Right Arm") then
		Framework.Viewmodel.RightArm.Color = Character["Right Arm"].Color
	end

	if Framework.Viewmodel:FindFirstChild("LeftArm") and Character:FindFirstChild("Left Arm") then
		Framework.Viewmodel.LeftArm.Color = Character["Left Arm"].Color
	end

	Framework._BuildTracks()

	do
		local Humanoid = Character:FindFirstChildOfClass("Humanoid")
		Framework._move_held = (Humanoid and Humanoid.MoveDirection.Magnitude > 0.05) and true or false
	end

	if Framework._tracks.Equip then
		local Action_Token = next_action_token()

		Framework._equip_playing = true
		Framework._weapon_locked = true

		Framework._current_state = "Equip"
		Framework._PlayTrack(Framework._tracks.Equip, Default_Fade)

		if Framework.Module and Framework.Module.ClientEquip then
			Framework.Module.ClientEquip(Framework)
		else
			Framework.PlaySfx("Equip", Framework.GetGunFrame() or Framework.Viewmodel, {Lifetime = 4})
		end

		if Framework._equip_conn then
			Framework._equip_conn:Disconnect()
		end

		Framework._equip_conn = Framework._tracks.Equip.Stopped:Connect(function()
			if not Framework.Viewmodel then
				return
			end

			Framework._equip_playing = false

			if not is_action_token_valid(Action_Token) then
				return
			end

			Framework._weapon_locked = false
			restore_base_animation(Action_Token)
		end)
	else
		Framework._equip_playing = false
		Framework._weapon_locked = false
		Framework.Idle()
		set_ammo_gui_visible(Framework.Viewmodel, true)
	end
end

return Framework-- this is module that basically handling client stuff like animation, SFX and VFX etc

local Framework = {}

-- Public
Framework.Viewmodel = nil
Framework.Module = nil

-- Internal state
Framework._tracks = {}
Framework._current_state = nil
Framework._move_held = false

Framework._equip_playing = false
Framework._shoot_playing = false
Framework._reload_playing = false
Framework._inspect_playing = false
Framework._weapon_locked = false

Framework._equip_conn = nil
Framework._shoot_conn = nil
Framework._reload_conn = nil
Framework._inspect_conn = nil

Framework._action_token = 0

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- Sway stuff
Framework._last_camera_cframe = nil
Framework._sway_rot = CFrame.new()
Framework._sway_pos = Vector3.new()

Framework.Sway = {
	Enabled = true,

	RotMultiplier = 1.15,
	PosMultiplier = 0.10,

	MaxRot = math.rad(8),
	MaxPos = 0.22,

	ReturnSpeed = 14,
	FollowSpeed = 22,
}

local Default_Fade = 0.12

-- GUI

-- some stupid stuff but there is a weapons that doesn't have one of those labels so I made those functions
local function get_ammo_label(viewmodel: Model?)
	if not viewmodel then
		return nil
	end

	local Ammo_Part = viewmodel:FindFirstChild("AmmoPart")
	if not Ammo_Part then
		return nil
	end

	local Surface_Gui = Ammo_Part:FindFirstChild("SurfaceGui")
	if not Surface_Gui then
		return nil
	end

	local Frame = Surface_Gui:FindFirstChild("Frame")
	if not Frame then
		return nil
	end

	return Frame:FindFirstChild("TextLabel")
end

local function get_ammo_frame(viewmodel: Model?)
	if not viewmodel then
		return nil
	end

	local Ammo_Part = viewmodel:FindFirstChild("AmmoPart")
	if not Ammo_Part then
		return nil
	end

	local Surface_Gui = Ammo_Part:FindFirstChild("SurfaceGui")
	if not Surface_Gui then
		return nil
	end

	return Surface_Gui:FindFirstChild("Frame")
end

local function update_ammo_gui(viewmodel: Model?, ammo, maxammo)
	local Text_Label = get_ammo_label(viewmodel)
	if not Text_Label then
		return
	end

	Text_Label.Text = tostring(ammo) .. "/" .. tostring(maxammo)
end

local function set_ammo_gui_visible(viewmodel: Model?, isvisible: boolean)
	local Ammo_Frame = get_ammo_frame(viewmodel)
	if not Ammo_Frame then
		return
	end

	if isvisible then
		Ammo_Frame.Visible = isvisible
		TweenService:Create(Ammo_Frame, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(1, 0, 1, 0)
		}):Play()
	else
		Ammo_Frame.Size = UDim2.new(1, 0, 1, 0)

		TweenService:Create(Ammo_Frame, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = UDim2.new(0, 0, 1, 0)
		}):Play()

		task.spawn(function()
			wait(0.5)

			if not Ammo_Frame then
				return
			end

			Ammo_Frame.Size = UDim2.new(0, 0, 1, 0)
			Ammo_Frame.Visible = isvisible
		end)
	end
end

function Framework.SetAmmo(ammo, maxammo, reserve, maxreserve)
	if not Framework.Viewmodel then
		return
	end

	update_ammo_gui(Framework.Viewmodel, ammo, maxammo)
	set_ammo_gui_visible(Framework.Viewmodel, true)
end

function Framework.SetAmmoVisible(isvisible: boolean)
	if not Framework.Viewmodel then
		return
	end

	set_ammo_gui_visible(Framework.Viewmodel, isvisible)
end

-- Preload animations
function Framework.PreloadAnimations(item: string)
	local Viewmodel_Folder = ReplicatedStorage:FindFirstChild("Models")
		and ReplicatedStorage.Models:FindFirstChild("Viewmodels")

	if not Viewmodel_Folder then
		return
	end

	local Viewmodel = Viewmodel_Folder:FindFirstChild(item)
	if not Viewmodel then
		return
	end

	local Animation_Folder = Viewmodel:FindFirstChild("Animations")
	if not Animation_Folder then
		return
	end

	local Assets = {}
	for _, Instance_Item in ipairs(Animation_Folder:GetDescendants()) do
		if Instance_Item:IsA("Animation") then
			table.insert(Assets, Instance_Item)
		end
	end

	if #Assets > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(Assets)
		end)
	end
end

-- Public helpers
function Framework.GetGunFrame(): Instance?
	if not Framework.Viewmodel then
		return nil
	end

	local Gun = Framework.Viewmodel:FindFirstChild("Gun")
	if not Gun then
		return nil
	end

	return Gun:FindFirstChild("Frame") or Gun
end

function Framework.GetBarrelAttachment(): Attachment?
	if not Framework.Viewmodel then
		return nil
	end

	local Barrel = Framework.Viewmodel:FindFirstChild("Gun") and Framework.Viewmodel.Gun:FindFirstChild("Barrel")
	if not Barrel then
		return nil
	end

	return Barrel:FindFirstChildWhichIsA("Attachment")
end

function Framework.PlaySfx(sfxname: string, parent: Instance?, settings: {Volume: number?, PlaybackSpeed: number?, TimePosition: number?, Lifetime: number?}?)
	if not Framework.Viewmodel then
		return
	end

	local Sfx_Folder = Framework.Viewmodel:FindFirstChild("SFX")
	if not Sfx_Folder then
		return
	end

	local Template = Sfx_Folder:FindFirstChild(sfxname)
	if not Template or not Template:IsA("Sound") then
		return
	end

	local Sound = Template:Clone()
	Sound.Parent = parent or Framework.Viewmodel

	if settings then
		if settings.Volume ~= nil then
			Sound.Volume = settings.Volume
		end

		if settings.PlaybackSpeed ~= nil then
			Sound.PlaybackSpeed = settings.PlaybackSpeed
		end

		if settings.TimePosition ~= nil then
			Sound.TimePosition = settings.TimePosition
		end
	end

	Sound:Play()
	Debris:AddItem(Sound, (settings and settings.Lifetime) or 6)
end

function Framework.PlayMuzzleFlash()
	local Attachment = Framework.GetBarrelAttachment()
	if not Attachment then
		return
	end

	for _, Instance_Item in ipairs(Attachment:GetChildren()) do
		if Instance_Item:IsA("ParticleEmitter") then
			Instance_Item:Emit(1)
		end
	end

	local Flash_Light = Attachment:FindFirstChildWhichIsA("PointLight")
	if Flash_Light then
		Flash_Light.Enabled = true

		local Old_Brightness = Flash_Light.Brightness
		Flash_Light.Brightness = Old_Brightness * (0.85 + math.random() * 0.3)

		task.delay(0.06, function()
			if Flash_Light then
				Flash_Light.Enabled = false
				Flash_Light.Brightness = Old_Brightness
			end
		end)
	end
end

-- Animation helpers
local function stop_all_except(excepttrack: AnimationTrack?, fadetime: number?)
	if not Framework.Viewmodel then
		return
	end

	local Controller: AnimationController = Framework.Viewmodel:FindFirstChild("AnimationController")
	if not Controller then
		return
	end

	for _, Track in ipairs(Controller:GetPlayingAnimationTracks()) do
		if Track ~= excepttrack then
			Track:Stop(fadetime or Default_Fade)
		end
	end
end

function Framework._PlayTrack(track: AnimationTrack?, fadetime: number?, speed: number?)
	if not track then
		return
	end

	fadetime = fadetime or Default_Fade

	if speed then
		track:AdjustSpeed(speed)
	end

	track:Play(fadetime)
	stop_all_except(track, fadetime)
end

local function apply_move_from_humanoid(): boolean
	local Player = game.Players.LocalPlayer
	local Camera = workspace.CurrentCamera
	local Character = Player.Character
	if not Character or not Camera then
		return false
	end

	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	if not Humanoid then
		return false
	end

	local Move_Direction = Humanoid.MoveDirection
	if Move_Direction.Magnitude < 0.05 then
		return false
	end

	local Local_Direction = Camera.CFrame:VectorToObjectSpace(Move_Direction)

	local Direction: string
	if math.abs(Local_Direction.Z) >= math.abs(Local_Direction.X) then
		Direction = (Local_Direction.Z < 0) and "Forward" or "Backward"
	else
		Direction = (Local_Direction.X > 0) and "Right" or "Left"
	end

	Framework._current_state = "Move:" .. Direction
	Framework._PlayTrack(Framework._tracks.Move and Framework._tracks.Move[Direction], Default_Fade)
	return true
end

local function next_action_token(): number
	Framework._action_token += 1
	return Framework._action_token
end

local function is_action_token_valid(token: number): boolean
	return token == Framework._action_token
end

local function restore_base_animation(token: number)
	if not is_action_token_valid(token) then
		return
	end

	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		return
	end

	if Framework._move_held then
		if not apply_move_from_humanoid() then
			Framework.Idle()
		end
	else
		Framework.Idle()
	end
end

function Framework._BuildTracks()
	if not Framework.Viewmodel then
		return
	end

	local Controller: AnimationController = Framework.Viewmodel:FindFirstChild("AnimationController")
	if not Controller then
		return
	end

	Framework._tracks = {}

	local Animation_Folder = Framework.Viewmodel:FindFirstChild("Animations")
	if not Animation_Folder then
		return
	end

	local Gun_Animation_Folder = Animation_Folder:FindFirstChild("Gun")

	if Animation_Folder:FindFirstChild("Idle") then
		Framework._tracks.Idle = Controller:LoadAnimation(Animation_Folder.Idle)
		Framework._tracks.Idle.Priority = Enum.AnimationPriority.Idle
		Framework._tracks.Idle.Looped = true
	end

	if Animation_Folder:FindFirstChild("Equip") then
		Framework._tracks.Equip = Controller:LoadAnimation(Animation_Folder.Equip)
		Framework._tracks.Equip.Priority = Enum.AnimationPriority.Action
		Framework._tracks.Equip.Looped = false
	end

	if Gun_Animation_Folder then
		if Gun_Animation_Folder:FindFirstChild("Inspect") then
			Framework._tracks.Inspect = Controller:LoadAnimation(Gun_Animation_Folder.Inspect)
			Framework._tracks.Inspect.Priority = Enum.AnimationPriority.Action
			Framework._tracks.Inspect.Looped = false
		end

		if Gun_Animation_Folder:FindFirstChild("Shoot") then
			Framework._tracks.Shoot = Controller:LoadAnimation(Gun_Animation_Folder.Shoot)
			Framework._tracks.Shoot.Priority = Enum.AnimationPriority.Action
			Framework._tracks.Shoot.Looped = false
		end

		if Gun_Animation_Folder:FindFirstChild("Reload") then
			Framework._tracks.Reload = Controller:LoadAnimation(Gun_Animation_Folder.Reload)
			Framework._tracks.Reload.Priority = Enum.AnimationPriority.Action
			Framework._tracks.Reload.Looped = false
		end
	end

	Framework._tracks.Move = {}
	local Move_Folder = Animation_Folder:FindFirstChild("Movement")
	if Move_Folder then
		for _, Direction_Name in ipairs({"Forward", "Backward", "Left", "Right"}) do
			if Move_Folder:FindFirstChild(Direction_Name) then
				local Track = Controller:LoadAnimation(Move_Folder[Direction_Name])
				Track.Priority = Enum.AnimationPriority.Movement
				Track.Looped = true
				Framework._tracks.Move[Direction_Name] = Track
			end
		end
	end
end

function Framework.ClearSlot()
	for _, Child in pairs(workspace.Camera:GetChildren()) do
		if Child:IsA("Model") then
			Child:Destroy()
		end
	end

	if Framework._equip_conn then
		Framework._equip_conn:Disconnect()
		Framework._equip_conn = nil
	end

	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
		Framework._inspect_conn = nil
	end

	if Framework._shoot_conn then
		Framework._shoot_conn:Disconnect()
		Framework._shoot_conn = nil
	end

	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
		Framework._reload_conn = nil
	end

	Framework._equip_playing = false
	Framework._inspect_playing = false
	Framework._shoot_playing = false
	Framework._reload_playing = false
	Framework._weapon_locked = false

	Framework._action_token = 0

	Framework.Viewmodel = nil
	Framework.Module = nil
	Framework._tracks = {}
	Framework._current_state = nil
	Framework._move_held = false

	Framework._last_camera_cframe = nil
	Framework._sway_rot = CFrame.new()
	Framework._sway_pos = Vector3.new()
end

function Framework.Idle()
	Framework._move_held = false
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		return
	end

	if Framework._current_state == "Idle" then
		return
	end

	Framework._current_state = "Idle"
	Framework._PlayTrack(Framework._tracks.Idle, Default_Fade)
end

function Framework.Movement(key: Enum.KeyCode)
	Framework._move_held = true
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		return
	end

	local Direction: string? = nil
	if key == Enum.KeyCode.W then
		Direction = "Forward"
	elseif key == Enum.KeyCode.S then
		Direction = "Backward"
	elseif key == Enum.KeyCode.D then
		Direction = "Right"
	elseif key == Enum.KeyCode.A then
		Direction = "Left"
	end

	if not Direction then
		return
	end

	Framework._current_state = "Move:" .. Direction
	Framework._PlayTrack(Framework._tracks.Move and Framework._tracks.Move[Direction], Default_Fade)
end

function Framework.Inspect()
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing then
		return
	end

	if Framework._inspect_playing then
		return
	end

	if not Framework._tracks.Inspect then
		return
	end

	local Action_Token = next_action_token()

	Framework._inspect_playing = true
	Framework._weapon_locked = true

	Framework._current_state = "Inspect"
	Framework._PlayTrack(Framework._tracks.Inspect, Default_Fade)

	if Framework.Module and Framework.Module.ClientInspect then
		Framework.Module.ClientInspect(Framework)
		set_ammo_gui_visible(Framework.Viewmodel, false)
	end

	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
	end

	Framework._inspect_conn = Framework._tracks.Inspect.Stopped:Connect(function()
		Framework._inspect_playing = false

		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		set_ammo_gui_visible(Framework.Viewmodel, true)

		restore_base_animation(Action_Token)
	end)
end

function Framework.CancelInspect()
	if not Framework._inspect_playing then
		return
	end

	next_action_token()

	Framework._inspect_playing = false
	Framework._weapon_locked = false
	set_ammo_gui_visible(Framework.Viewmodel, true)

	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
		Framework._inspect_conn = nil
	end

	if Framework._tracks.Inspect then
		pcall(function()
			Framework._tracks.Inspect:Stop(0)
		end)
	end

	if Framework.Module and Framework.Module.ClientCancelInspect then
		Framework.Module.ClientCancelInspect(Framework)
	end

	restore_base_animation(Framework._action_token)
end

function Framework.Shoot()
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing then
		return
	end

	if not Framework._tracks.Shoot then
		return
	end

	local Action_Token = next_action_token()

	Framework._weapon_locked = true
	Framework._shoot_playing = true

	Framework._current_state = "Shoot"
	Framework._PlayTrack(Framework._tracks.Shoot, Default_Fade)

	if Framework.Module and Framework.Module.ClientShoot then
		Framework.Module.ClientShoot(Framework)
	end

	if Framework._shoot_conn then
		Framework._shoot_conn:Disconnect()
	end

	Framework._shoot_conn = Framework._tracks.Shoot.Stopped:Connect(function()
		Framework._shoot_playing = false

		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		restore_base_animation(Action_Token)
	end)
end

function Framework.Reload()
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing then
		return
	end

	if not Framework._tracks.Reload then
		return
	end

	local Action_Token = next_action_token()

	Framework._weapon_locked = true
	Framework._reload_playing = true

	Framework._current_state = "Reload"
	Framework._PlayTrack(Framework._tracks.Reload, Default_Fade)
	set_ammo_gui_visible(Framework.Viewmodel, false)

	if Framework.Module and Framework.Module.ClientReload then
		Framework.Module.ClientReload(Framework)
	end

	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
	end

	Framework._reload_conn = Framework._tracks.Reload.Stopped:Connect(function()
		Framework._reload_playing = false

		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		set_ammo_gui_visible(Framework.Viewmodel, true)

		restore_base_animation(Action_Token)
	end)
end

function Framework.CancelReload()
	if not Framework._reload_playing then
		return
	end

	next_action_token()

	Framework._reload_playing = false
	Framework._weapon_locked = false

	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
		Framework._reload_conn = nil
	end

	if Framework._tracks.Reload then
		pcall(function()
			Framework._tracks.Reload:Stop(0)
		end)
	end

	if Framework.Module and Framework.Module.ClientCancelReload then
		Framework.Module.ClientCancelReload(Framework)
	end

	set_ammo_gui_visible(Framework.Viewmodel, true)
	restore_base_animation(Framework._action_token)
end

function Framework.Dry()
	if not Framework.Viewmodel then
		return
	end

	if Framework._equip_playing then
		return
	end

	if Framework.Module and Framework.Module.ClientDry then
		Framework.Module.ClientDry(Framework)
		return
	end

	Framework.PlaySfx("DryClick", Framework.GetGunFrame() or Framework.Viewmodel, {Lifetime = 4})
end

-- World shot fx
local function render_tracer(origin: Vector3, endpos: Vector3)
	local Delta = endpos - origin
	local Distance = Delta.Magnitude
	if Distance < 0.2 then
		return
	end

	if Distance > 1500 then
		endpos = origin + Delta.Unit * 1500
		Delta = endpos - origin
		Distance = Delta.Magnitude
	end

	local Midpoint = origin + Delta * 0.5

	local Tracer = Instance.new("Part")
	Tracer.Name = "Tracer"
	Tracer.Anchored = true
	Tracer.CanCollide = false
	Tracer.CanQuery = false
	Tracer.CanTouch = false
	Tracer.Material = Enum.Material.Neon
	Tracer.Transparency = 0.15
	Tracer.Size = Vector3.new(0.04, 0.04, Distance)
	Tracer.CFrame = CFrame.lookAt(Midpoint, endpos)
	Tracer.Parent = workspace

	Debris:AddItem(Tracer, 0.05)
end

local function render_impact(endpos: Vector3)
	local Part = Instance.new("Part")
	Part.Anchored = true
	Part.CanCollide = false
	Part.CanQuery = false
	Part.CanTouch = false
	Part.Transparency = 1
	Part.Size = Vector3.new(0.2, 0.2, 0.2)
	Part.CFrame = CFrame.new(endpos)
	Part.Parent = workspace

	local Light = Instance.new("PointLight")
	Light.Brightness = 2
	Light.Range = 6
	Light.Parent = Part

	Debris:AddItem(Part, 0.08)
end

function Framework.RenderShotFX(shooterplayer: Player, weaponname: string, origin: Vector3, dir: Vector3, endpos: Vector3, hit: any)
	if typeof(origin) == "Vector3" and typeof(endpos) == "Vector3" then
		render_tracer(origin, endpos)
	end

	if hit == true then
		render_impact(endpos)
	end
end

-- Viewmodel sway
function Framework.StepViewmodel(cameracframe: CFrame, dt: number)
	if not Framework.Viewmodel then
		Framework._last_camera_cframe = cameracframe
		return
	end

	local Camera_Part = Framework.Viewmodel:FindFirstChild("Camera")
	if not Camera_Part or not Camera_Part:IsA("BasePart") then
		Framework._last_camera_cframe = cameracframe
		return
	end

	if not Framework.Sway.Enabled then
		Camera_Part.CFrame = cameracframe
		Framework._last_camera_cframe = cameracframe
		return
	end

	if not Framework._last_camera_cframe then
		Framework._last_camera_cframe = cameracframe
		Camera_Part.CFrame = cameracframe
		return
	end

	local Delta = Framework._last_camera_cframe:ToObjectSpace(cameracframe)
	local Pitch, Yaw, Roll = Delta:ToOrientation()

	local Target_Rot_X = math.clamp(-Pitch * Framework.Sway.RotMultiplier, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)
	local Target_Rot_Y = math.clamp(-Yaw * Framework.Sway.RotMultiplier, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)
	local Target_Roll = math.clamp(-Roll * 0.25, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)

	local Target_Rotation = CFrame.Angles(Target_Rot_X, Target_Rot_Y, Target_Roll)

	local Target_Position = Vector3.new(
		math.clamp(-Yaw * Framework.Sway.PosMultiplier, -Framework.Sway.MaxPos, Framework.Sway.MaxPos),
		math.clamp(-Pitch * Framework.Sway.PosMultiplier, -Framework.Sway.MaxPos, Framework.Sway.MaxPos),
		0
	)

	local Follow_Alpha = 1 - math.exp(-dt * Framework.Sway.FollowSpeed)
	local Return_Alpha = 1 - math.exp(-dt * Framework.Sway.ReturnSpeed)

	Framework._sway_pos = Framework._sway_pos:Lerp(Target_Position, Follow_Alpha)
	Framework._sway_rot = Framework._sway_rot:Lerp(Target_Rotation, Return_Alpha)

	Camera_Part.CFrame = cameracframe * CFrame.new(Framework._sway_pos) * Framework._sway_rot
	Framework._last_camera_cframe = cameracframe
end

function Framework.LoadSlot(item: string)
	Framework.ClearSlot()

	local Player = game.Players.LocalPlayer
	local Character = Player.Character
	local Camera = workspace.CurrentCamera

	local Viewmodel_Folder = ReplicatedStorage.Models.Viewmodels
	local Modules = ReplicatedStorage.Modules.Framework

	if Modules:FindFirstChild(item) then
		Framework.Module = require(Modules:FindFirstChild(item))
	else
		Framework.Module = nil
	end

	if Viewmodel_Folder:FindFirstChild(item) then
		Framework.Viewmodel = Viewmodel_Folder[item]:Clone()
		Framework.Viewmodel.Parent = Camera
	else
		return
	end
	
	Framework.Viewmodel.RightArm.Color = Character["Right Arm"].Color
	Framework.Viewmodel.LeftArm.Color = Character["Left Arm"].Color

	Framework._BuildTracks()

	do
		local Character = Player.Character
		local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
		Framework._move_held = (Humanoid and Humanoid.MoveDirection.Magnitude > 0.05) and true or false
	end

	if Framework._tracks.Equip then
		local Action_Token = next_action_token()

		Framework._equip_playing = true
		Framework._weapon_locked = true

		Framework._current_state = "Equip"
		Framework._PlayTrack(Framework._tracks.Equip, Default_Fade)

		if Framework.Module and Framework.Module.ClientEquip then
			Framework.Module.ClientEquip(Framework)
		else
			Framework.PlaySfx("Equip", Framework.GetGunFrame() or Framework.Viewmodel, {Lifetime = 4})
		end

		if Framework._equip_conn then
			Framework._equip_conn:Disconnect()
		end

		Framework._equip_conn = Framework._tracks.Equip.Stopped:Connect(function()
			if not Framework.Viewmodel then
				return
			end

			Framework._equip_playing = false

			if not is_action_token_valid(Action_Token) then
				return
			end

			Framework._weapon_locked = false
			restore_base_animation(Action_Token)
		end)
	else
		Framework._equip_playing = false
		Framework._weapon_locked = false
		Framework.Idle()
		set_ammo_gui_visible(Framework.Viewmodel, true)
	end
end

return Framework
