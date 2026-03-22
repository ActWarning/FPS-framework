-- Hey!! Thank you for explaining my mistakes. 
--This time, I tried my best to describe my code more clearly and replace all old waits. 
--I think I might have overdone it, but I guess that’s better than not doing enough. 
--Anyway, thank you for your reply. I really hope I’ll be accepted this time!


-- This module handles the local first person weapon viewmodel.
-- building and playing animation tracks, updating the ammo gui,
-- spawning simple local effects and applying viewmodel sway.

local Framework = {}

-- Public references
-- Viewmodel stores the currently loaded first person weapon model.
-- Module stores the optional per-weapon client module if one exists.
Framework.Viewmodel = nil
Framework.Module = nil

-- Internal animation and state data
-- _tracks keeps all loaded animation tracks for the current weapon.
-- _current_state is used to avoid replaying the same state repeatedly.
-- _move_held remembers whether the player is currently trying to move.
Framework._tracks = {}
Framework._current_state = nil
Framework._move_held = false

-- Action flags
-- These flags tell the module whether a one-shot action is currently active.
-- They are checked before changing animations so actions do not interrupt each other in bad ways.
Framework._equip_playing = false
Framework._shoot_playing = false
Framework._reload_playing = false
Framework._inspect_playing = false
Framework._weapon_locked = false

-- Stored connections for one-shot tracks
-- Each action track uses .Stopped so the module can restore the correct base animation after it ends.
Framework._equip_conn = nil
Framework._shoot_conn = nil
Framework._reload_conn = nil
Framework._inspect_conn = nil

-- Action token
-- Every time a new one-shot action starts, this number is increased.
-- Old callbacks keep the token they were created with.
-- If an old callback fires after a newer action already started,
-- the token check will stop it from restoring the wrong state.
Framework._action_token = 0

-- Services used by the module
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- Sway state
-- _last_camera_cframe stores the camera transform from the previous frame.
-- The module compares the old camera transform with the new one to know how the camera moved.
-- _sway_rot and _sway_pos are blended values that make the weapon follow the camera smoothly.
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

-- Returns the ammo text label from the current viewmodel.
-- The function checks every object step by step because some weapons may not have this gui at all.
-- Returning nil lets the caller exit safely instead of throwing an indexing error.
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

-- Returns the ammo gui frame that gets tweened open and closed.
-- This uses the same safe lookup style as get_ammo_label for the same reason:
-- not every viewmodel is guaranteed to contain every gui object.
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

-- Updates the visible ammo text on the viewmodel.
-- If the label does not exist, the function simply returns so the caller does not fail.
local function update_ammo_gui(viewmodel: Model?, ammo, maxammo)
	local Text_Label = get_ammo_label(viewmodel)
	if not Text_Label then
		return
	end

	Text_Label.Text = tostring(ammo) .. "/" .. tostring(maxammo)
end

-- Shows or hides the ammo gui frame.
-- When showing it, the frame becomes visible first and then expands to full width.
-- When hiding it, the frame shrinks first, then becomes invisible after the tween is done.
-- The delayed hide is needed so the closing tween can actually be seen.
local function set_ammo_gui_visible(viewmodel: Model?, isvisible: boolean)
	local Ammo_Frame = get_ammo_frame(viewmodel)
	if not Ammo_Frame then
		return
	end

	if isvisible then
		Ammo_Frame.Visible = true

		TweenService:Create(
			Ammo_Frame,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				Size = UDim2.new(1, 0, 1, 0)
			}
		):Play()
	else
		Ammo_Frame.Size = UDim2.new(1, 0, 1, 0)

		TweenService:Create(
			Ammo_Frame,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{
				Size = UDim2.new(0, 0, 1, 0)
			}
		):Play()

		task.spawn(function()
			-- Wait for the close tween to finish before hiding the frame completely.
			task.wait(0.5)

			-- Check the frame again in case the viewmodel was removed while waiting.
			if not Ammo_Frame or not Ammo_Frame.Parent then
				return
			end

			Ammo_Frame.Size = UDim2.new(0, 0, 1, 0)
			Ammo_Frame.Visible = false
		end)
	end
end

function Framework.SetAmmo(ammo, maxammo, reserve, maxreserve)
	-- If no viewmodel is loaded yet, there is nothing to update.
	if not Framework.Viewmodel then
		return
	end

	-- reserve and maxreserve are kept in the function signature so outside code
	-- can still call this function with the same arguments even though this gui only shows mag ammo.
	update_ammo_gui(Framework.Viewmodel, ammo, maxammo)
	set_ammo_gui_visible(Framework.Viewmodel, true)
end

function Framework.SetAmmoVisible(isvisible: boolean)
	-- Exit early if the weapon is not loaded.
	if not Framework.Viewmodel then
		return
	end

	set_ammo_gui_visible(Framework.Viewmodel, isvisible)
end

-- Finds the AnimationController inside the current viewmodel.
-- The controller is needed so the module can locate the Animator.
local function get_animation_controller(viewmodel: Model?): AnimationController?
	if not viewmodel then
		return nil
	end

	return viewmodel:FindFirstChild("AnimationController")
end

-- Finds the Animator inside the AnimationController.
-- If the Animator does not exist yet, it is created once and parented to the controller.
-- The Animator is what actually loads and manages the animation tracks.
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

-- Loads a single animation object into an AnimationTrack through the Animator.
-- If the viewmodel, animation controller or animator is missing, the function returns nil.
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

-- Stops every currently playing track except the one that was just started.
-- This prevents old movement or idle tracks from blending over a one-shot track.
local function stop_all_except(excepttrack: AnimationTrack?, fadetime: number?)
	-- If the viewmodel does not exist, there are no tracks to stop.
	if not Framework.Viewmodel then
		return
	end

	local Animator_Object = get_animator(Framework.Viewmodel)
	if not Animator_Object then
		return
	end

	-- Iterate through every playing track on the animator.
	-- Any track that is not the one we want to keep gets stopped.
	for _, Track in ipairs(Animator_Object:GetPlayingAnimationTracks()) do
		if Track ~= excepttrack then
			Track:Stop(fadetime or Default_Fade)
		end
	end
end

-- Plays a given track and then stops all other currently playing tracks.
-- Optional speed is applied before the track starts.
function Framework._PlayTrack(track: AnimationTrack?, fadetime: number?, speed: number?)
	-- If the caller passed no track, there is nothing to play.
	if not track then
		return
	end

	fadetime = fadetime or Default_Fade

	-- Only adjust speed when the caller asked for it.
	if speed then
		track:AdjustSpeed(speed)
	end

	track:Play(fadetime)
	stop_all_except(track, fadetime)
end

-- Reads the Humanoid move direction and converts it into a local movement animation.
-- The movement vector is converted into camera-local space so the chosen animation matches
-- the player's first person direction instead of world direction.
local function apply_move_from_humanoid(): boolean
	local Player = Players.LocalPlayer
	local Camera = workspace.CurrentCamera
	local Character = Player.Character

	-- The movement state cannot be calculated if either the character or the camera is missing.
	if not Character or not Camera then
		return false
	end

	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	if not Humanoid then
		return false
	end

	local Move_Direction = Humanoid.MoveDirection

	-- Ignore tiny movement values so idle does not constantly switch to move from tiny float changes.
	if Move_Direction.Magnitude < 0.05 then
		return false
	end

	local Local_Direction = Camera.CFrame:VectorToObjectSpace(Move_Direction)

	local Direction: string

	-- Compare forward/back strength with left/right strength.
	-- The larger axis decides which movement animation should play.
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
-- Starting a new action always invalidates older callbacks.
local function next_action_token(): number
	Framework._action_token += 1
	return Framework._action_token
end

-- Checks whether a saved token still belongs to the current action.
-- If it does not match, the callback is old and should not change the current state.
local function is_action_token_valid(token: number): boolean
	return token == Framework._action_token
end

-- Restores the correct base animation after a one-shot animation ends.
-- First it verifies that the callback is still current.
-- Then it makes sure no other one-shot action is active.
-- If the player is moving, it tries to restore the correct movement animation.
-- If movement cannot be resolved, it falls back to idle.
local function restore_base_animation(token: number)
	-- Ignore callbacks from older actions that no longer own the current state.
	if not is_action_token_valid(token) then
		return
	end

	-- Do not restore idle or move while another action is still playing.
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

-- Builds all animation tracks from the current viewmodel.
-- The function looks for the standard folder layout under Viewmodel.Animations
-- and creates tracks only for the animations that actually exist.
function Framework._BuildTracks()
	-- No viewmodel means there is nothing to build tracks from.
	if not Framework.Viewmodel then
		return
	end

	Framework._tracks = {}

	local Animation_Folder = Framework.Viewmodel:FindFirstChild("Animations")
	if not Animation_Folder then
		return
	end

	local Gun_Animation_Folder = Animation_Folder:FindFirstChild("Gun")

	-- Idle is looped because it is the default resting state.
	if Animation_Folder:FindFirstChild("Idle") then
		Framework._tracks.Idle = load_track(Framework.Viewmodel, Animation_Folder.Idle)

		if Framework._tracks.Idle then
			Framework._tracks.Idle.Priority = Enum.AnimationPriority.Idle
			Framework._tracks.Idle.Looped = true
		end
	end

	-- Equip is a one-shot action, so it is not looped.
	if Animation_Folder:FindFirstChild("Equip") then
		Framework._tracks.Equip = load_track(Framework.Viewmodel, Animation_Folder.Equip)

		if Framework._tracks.Equip then
			Framework._tracks.Equip.Priority = Enum.AnimationPriority.Action
			Framework._tracks.Equip.Looped = false
		end
	end

	if Gun_Animation_Folder then
		-- Inspect is optional, so it is only created if the animation exists.
		if Gun_Animation_Folder:FindFirstChild("Inspect") then
			Framework._tracks.Inspect = load_track(Framework.Viewmodel, Gun_Animation_Folder.Inspect)

			if Framework._tracks.Inspect then
				Framework._tracks.Inspect.Priority = Enum.AnimationPriority.Action
				Framework._tracks.Inspect.Looped = false
			end
		end

		-- Shoot is also a one-shot track.
		if Gun_Animation_Folder:FindFirstChild("Shoot") then
			Framework._tracks.Shoot = load_track(Framework.Viewmodel, Gun_Animation_Folder.Shoot)

			if Framework._tracks.Shoot then
				Framework._tracks.Shoot.Priority = Enum.AnimationPriority.Action
				Framework._tracks.Shoot.Looped = false
			end
		end

		-- Reload is also a one-shot track.
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
		-- Iterate through each expected movement direction and load it if present.
		-- Missing directions are simply skipped so the code still works with partial animation sets.
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

-- Preloads all Animation objects found in the weapon viewmodel.
-- This helps reduce the first-time hitch when the weapon is equipped.
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

	-- Walk through every descendant under the animation folder.
	-- Only Animation instances are collected because those are the assets we want to preload.
	for _, Instance_Item in ipairs(Animation_Folder:GetDescendants()) do
		if Instance_Item:IsA("Animation") then
			table.insert(Assets, Instance_Item)
		end
	end

	-- Preload only when there is at least one asset to request.
	if #Assets > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(Assets)
		end)
	end
end

-- Returns the gun frame part if it exists.
-- If the frame part does not exist, the gun object itself is returned as a fallback parent for effects.
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

-- Plays a sound from the current weapon SFX folder.
-- The sound is cloned so multiple sounds can play independently without reusing the template instance.
function Framework.PlaySfx(
	sfxname: string,
	parent: Instance?,
	settings: {Volume: number?, PlaybackSpeed: number?, TimePosition: number?, Lifetime: number?}?
)
	if not Framework.Viewmodel then
		return
	end

	local Sfx_Folder = Framework.Viewmodel:FindFirstChild("SFX")
	if not Sfx_Folder then
		return
	end

	local Template = Sfx_Folder:FindFirstChild(sfxname)

	-- If the requested object does not exist or is not a Sound, exit safely.
	if not Template or not Template:IsA("Sound") then
		return
	end

	local Sound = Template:Clone()
	Sound.Parent = parent or Framework.Viewmodel

	if settings then
		-- Apply overrides only for fields that were actually provided by the caller.
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

-- Emits the muzzle particle effects and flashes the point light very briefly.
-- The light brightness is randomized a little so repeated shots feel less static.
function Framework.PlayMuzzleFlash()
	local Attachment = Framework.GetBarrelAttachment()
	if not Attachment then
		return
	end

	-- Iterate over all children of the barrel attachment and emit any particle emitter found there.
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
			-- Check the light again before touching it, because the viewmodel may have been removed already.
			if Flash_Light and Flash_Light.Parent then
				Flash_Light.Enabled = false
				Flash_Light.Brightness = Old_Brightness
			end
		end)
	end
end

-- Removes the currently loaded slot and resets all local state.
-- This is called before loading a new weapon so old models, tracks and callbacks do not leak into the new slot.
function Framework.ClearSlot()
	local Camera = workspace.CurrentCamera

	-- Destroy any model currently parented to the camera.
	-- This clears the old first person weapon model before a new one is loaded.
	if Camera then
		for _, Child in pairs(Camera:GetChildren()) do
			if Child:IsA("Model") then
				Child:Destroy()
			end
		end
	end

	-- Disconnect all old one-shot listeners so they cannot fire after the slot is gone.
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

-- Plays the idle animation when no one-shot action is running.
function Framework.Idle()
	-- Mark movement as not held when switching directly to idle.
	Framework._move_held = false

	if not Framework.Viewmodel then
		return
	end

	-- Do not replace a one-shot action with idle.
	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		return
	end

	-- Avoid replaying idle if idle is already the current state.
	if Framework._current_state == "Idle" then
		return
	end

	Framework._current_state = "Idle"
	Framework._PlayTrack(Framework._tracks.Idle, Default_Fade)
end

-- Starts a movement animation from a keyboard key.
-- This is a fast local state switch used while movement input is being held.
function Framework.Movement(key: Enum.KeyCode)
	Framework._move_held = true

	if not Framework.Viewmodel then
		return
	end

	-- Do not allow movement animations to replace an important one-shot action.
	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		return
	end

	local Direction: string? = nil

	-- Translate the input key into the animation direction name.
	if key == Enum.KeyCode.W then
		Direction = "Forward"
	elseif key == Enum.KeyCode.S then
		Direction = "Backward"
	elseif key == Enum.KeyCode.D then
		Direction = "Right"
	elseif key == Enum.KeyCode.A then
		Direction = "Left"
	end

	-- Ignore keys that are not movement keys.
	if not Direction then
		return
	end

	Framework._current_state = "Move:" .. Direction
	Framework._PlayTrack(Framework._tracks.Move and Framework._tracks.Move[Direction], Default_Fade)
end

-- Plays the inspect animation if the weapon is free to inspect.
-- The ammo gui is hidden during the inspect animation and restored afterwards.
function Framework.Inspect()
	if not Framework.Viewmodel then
		return
	end

	-- Do not start inspect if equip is still playing or inspect is already active.
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
		-- Mark inspect as finished as soon as the track stops.
		Framework._inspect_playing = false

		-- If this callback belongs to an older action, do nothing.
		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		set_ammo_gui_visible(Framework.Viewmodel, true)
		restore_base_animation(Action_Token)
	end)
end

-- Cancels the current inspect action immediately.
-- The token is advanced first so any delayed callback from the old inspect track becomes invalid.
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

	-- Do not allow shooting during equip.
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

		-- Ignore the callback if a newer action already replaced this one.
		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		restore_base_animation(Action_Token)
	end)
end

-- Plays the reload animation and hides the ammo gui until the reload ends.
function Framework.Reload()
	if not Framework.Viewmodel then
		return
	end

	-- Do not allow reload during equip.
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

		-- Ignore this callback if reload was replaced or cancelled and a newer action started.
		if not is_action_token_valid(Action_Token) then
			return
		end

		Framework._weapon_locked = false
		set_ammo_gui_visible(Framework.Viewmodel, true)
		restore_base_animation(Action_Token)
	end)
end

-- Cancels reload immediately and returns to the proper base animation.
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

-- Plays the dry fire behaviour.
-- A custom per-weapon handler is used first if one exists.
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

-- Creates a very short-lived tracer part between the start and end positions.
local function render_tracer(origin: Vector3, endpos: Vector3)
	local Delta = endpos - origin
	local Distance = Delta.Magnitude

	-- Ignore extremely short traces because they would not be visible anyway.
	if Distance < 0.2 then
		return
	end

	-- Clamp very long tracers so a bad end position does not create an extreme part.
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

-- Creates a short-lived invisible part with a point light at the hit position.
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

-- Renders simple world-space shot effects from replicated shot data.
function Framework.RenderShotFX(shooterplayer: Player, weaponname: string, origin: Vector3, dir: Vector3, endpos: Vector3, hit: any)
	-- Only render the tracer when both positions were provided correctly.
	if typeof(origin) == "Vector3" and typeof(endpos) == "Vector3" then
		render_tracer(origin, endpos)
	end

	-- Only spawn the impact flash if the caller says the shot hit something.
	if hit == true then
		render_impact(endpos)
	end
end

-- Applies viewmodel sway based on how the camera moved since the previous frame.
-- The camera delta is converted into small target rotation and position offsets.
-- Those offsets are then smoothly lerped so the viewmodel lags behind the camera slightly.
function Framework.StepViewmodel(cameracframe: CFrame, dt: number)
	-- If there is no viewmodel, only update the cached camera transform and exit.
	if not Framework.Viewmodel then
		Framework._last_camera_cframe = cameracframe
		return
	end

	local Camera_Part = Framework.Viewmodel:FindFirstChild("Camera")

	-- The sway is applied to the viewmodel's camera part.
	-- If it does not exist or is not a BasePart, the function cannot continue safely.
	if not Camera_Part or not Camera_Part:IsA("BasePart") then
		Framework._last_camera_cframe = cameracframe
		return
	end

	-- If sway is disabled, keep the camera part directly on the real camera transform.
	if not Framework.Sway.Enabled then
		Camera_Part.CFrame = cameracframe
		Framework._last_camera_cframe = cameracframe
		return
	end

	-- On the first frame there is no previous camera transform to compare against.
	-- Store the current transform and place the camera part directly there.
	if not Framework._last_camera_cframe then
		Framework._last_camera_cframe = cameracframe
		Camera_Part.CFrame = cameracframe
		return
	end

	local Delta = Framework._last_camera_cframe:ToObjectSpace(cameracframe)
	local Pitch, Yaw, Roll = Delta:ToOrientation()

	-- Convert the camera delta into target rotational sway values.
	-- Clamp them so fast mouse movement cannot push the viewmodel too far.
	local Target_Rot_X = math.clamp(-Pitch * Framework.Sway.RotMultiplier, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)
	local Target_Rot_Y = math.clamp(-Yaw * Framework.Sway.RotMultiplier, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)
	local Target_Roll = math.clamp(-Roll * 0.25, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)

	local Target_Rotation = CFrame.Angles(Target_Rot_X, Target_Rot_Y, Target_Roll)

	-- Convert the same camera delta into a small positional sway.
	-- This gives the viewmodel a little side-to-side and up-down motion.
	local Target_Position = Vector3.new(
		math.clamp(-Yaw * Framework.Sway.PosMultiplier, -Framework.Sway.MaxPos, Framework.Sway.MaxPos),
		math.clamp(-Pitch * Framework.Sway.PosMultiplier, -Framework.Sway.MaxPos, Framework.Sway.MaxPos),
		0
	)

	-- These alphas control how quickly the viewmodel follows and settles.
	local Follow_Alpha = 1 - math.exp(-dt * Framework.Sway.FollowSpeed)
	local Return_Alpha = 1 - math.exp(-dt * Framework.Sway.ReturnSpeed)

	Framework._sway_pos = Framework._sway_pos:Lerp(Target_Position, Follow_Alpha)
	Framework._sway_rot = Framework._sway_rot:Lerp(Target_Rotation, Return_Alpha)

	Camera_Part.CFrame = cameracframe * CFrame.new(Framework._sway_pos) * Framework._sway_rot
	Framework._last_camera_cframe = cameracframe
end

-- Loads a new weapon slot into the camera.
-- The old slot is cleared first so no old models or callbacks remain.
-- Then the new viewmodel is cloned, weapon tracks are built and equip or idle is started.
function Framework.LoadSlot(item: string)
	Framework.ClearSlot()

	local Player = Players.LocalPlayer
	local Character = Player.Character
	local Camera = workspace.CurrentCamera

	-- The slot cannot be loaded unless both the character and camera are available.
	if not Character or not Camera then
		return
	end

	local Models_Folder = ReplicatedStorage:FindFirstChild("Models")
	local Viewmodel_Folder = Models_Folder and Models_Folder:FindFirstChild("Viewmodels")
	local Modules_Folder = ReplicatedStorage:FindFirstChild("Modules")
	local Framework_Folder = Modules_Folder and Modules_Folder:FindFirstChild("Framework")

	if Framework_Folder and Framework_Folder:FindFirstChild(item) then
		Framework.Module = require(Framework_Folder[item])
	else
		Framework.Module = nil
	end

	if Viewmodel_Folder and Viewmodel_Folder:FindFirstChild(item) then
		Framework.Viewmodel = Viewmodel_Folder[item]:Clone()
		Framework.Viewmodel.Parent = Camera
	else
		return
	end

	-- Copy the player arm colors onto the first person arms so the viewmodel matches the current character.
	if Framework.Viewmodel:FindFirstChild("RightArm") and Character:FindFirstChild("Right Arm") then
		Framework.Viewmodel.RightArm.Color = Character["Right Arm"].Color
	end

	if Framework.Viewmodel:FindFirstChild("LeftArm") and Character:FindFirstChild("Left Arm") then
		Framework.Viewmodel.LeftArm.Color = Character["Left Arm"].Color
	end

	Framework._BuildTracks()

	do
		local Humanoid = Character:FindFirstChildOfClass("Humanoid")

		-- If the player was already moving while the slot was loaded,
		-- remember that so the module can return to movement instead of idle after equip.
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
			-- The viewmodel may have been cleared while equip was still playing.
			if not Framework.Viewmodel then
				return
			end

			Framework._equip_playing = false

			-- Ignore this callback if another newer action already replaced equip.
			if not is_action_token_valid(Action_Token) then
				return
			end

			Framework._weapon_locked = false
			restore_base_animation(Action_Token)
		end)
	else
		-- If there is no equip track, go directly to the base state.
		Framework._equip_playing = false
		Framework._weapon_locked = false
		Framework.Idle()
		set_ammo_gui_visible(Framework.Viewmodel, true)
	end
end

return Framework
