-- This module handles the client-side weapon viewmodel
-- It loads the viewmodel into the camera, plays local animations,
-- updates the ammo gui, plays local effects, and applies sway

local Framework = {}

-- Store the current first person weapon model here
Framework.Viewmodel = nil

-- Store the optional per-weapon client module here
Framework.Module = nil

-- Keep every loaded animation track for the current weapon here
Framework._tracks = {}

-- Keep the current animation state here so the same state does not get replayed for no reason
Framework._current_state = nil

-- Remember whether movement input is currently being held
Framework._move_held = false

-- These flags tell the module which one-shot action is currently active
Framework._equip_playing = false
Framework._shoot_playing = false
Framework._reload_playing = false
Framework._inspect_playing = false
Framework._weapon_locked = false

-- Store the connections for one-shot animation callbacks here
Framework._equip_conn = nil
Framework._shoot_conn = nil
Framework._reload_conn = nil
Framework._inspect_conn = nil

-- Store the action token here
-- A newer action increases this value so old callbacks can be ignored safely
Framework._action_token = 0

-- Services used by this module
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- These values store the current sway state between frames
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

-- Try to get the ammo label from the viewmodel
local function get_ammo_label(viewmodel: Model?)
	-- If there is no viewmodel, then there is nowhere to read gui objects from
	if not viewmodel then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Try to get the AmmoPart from the viewmodel
	local Ammo_Part = viewmodel:FindFirstChild("AmmoPart")

	-- If the weapon does not have an AmmoPart, then this weapon simply has no ammo gui
	if not Ammo_Part then
		-- Return nil so the caller knows the label does not exist
		return nil
	end

	-- Try to get the SurfaceGui from AmmoPart
	local Surface_Gui = Ammo_Part:FindFirstChild("SurfaceGui")

	-- If the SurfaceGui is missing, then the ammo label cannot be reached
	if not Surface_Gui then
		-- Return nil because the gui path is incomplete
		return nil
	end

	-- Try to get the Frame inside the SurfaceGui
	local Frame = Surface_Gui:FindFirstChild("Frame")

	-- If the Frame is missing, then there is still no valid label to return
	if not Frame then
		-- Return nil so the caller does not index a missing object
		return nil
	end

	-- Return the TextLabel if it exists
	return Frame:FindFirstChild("TextLabel")
end

-- Try to get the ammo frame from the viewmodel
local function get_ammo_frame(viewmodel: Model?)
	-- If there is no viewmodel, then there is nowhere to read gui objects from
	if not viewmodel then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Try to get the AmmoPart from the viewmodel
	local Ammo_Part = viewmodel:FindFirstChild("AmmoPart")

	-- If the weapon does not have an AmmoPart, then there is no ammo frame to return
	if not Ammo_Part then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Try to get the SurfaceGui from AmmoPart
	local Surface_Gui = Ammo_Part:FindFirstChild("SurfaceGui")

	-- If the SurfaceGui is missing, then the frame cannot be reached
	if not Surface_Gui then
		-- Return nil because the gui path is incomplete
		return nil
	end

	-- Return the frame object if it exists
	return Surface_Gui:FindFirstChild("Frame")
end

-- Update the ammo text on the current viewmodel
local function update_ammo_gui(viewmodel: Model?, ammo, maxammo)
	-- Ask the helper for the label
	local Text_Label = get_ammo_label(viewmodel)

	-- If no label was found, then this weapon does not support this gui path
	if not Text_Label then
		-- Return so the function does not try to write into nil
		return
	end

	-- Write the ammo text in the format current/max
	Text_Label.Text = tostring(ammo) .. "/" .. tostring(maxammo)
end

-- Show or hide the ammo frame with a tween
local function set_ammo_gui_visible(viewmodel: Model?, isvisible: boolean)
	-- Ask the helper for the frame
	local Ammo_Frame = get_ammo_frame(viewmodel)

	-- If the frame does not exist, then there is nothing to tween
	if not Ammo_Frame then
		-- Return so the function stops safely
		return
	end

	-- If isvisible is true, then the frame should open and become visible
	if isvisible then
		-- Make the frame visible before the tween starts
		Ammo_Frame.Visible = true

		-- Tween the frame to full size so it expands open
		TweenService:Create(
			Ammo_Frame,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				Size = UDim2.new(1, 0, 1, 0)
			}
		):Play()
	else
		-- If isvisible is false, then start from full size before closing the frame
		Ammo_Frame.Size = UDim2.new(1, 0, 1, 0)

		-- Tween the frame width down to zero so it closes smoothly
		TweenService:Create(
			Ammo_Frame,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{
				Size = UDim2.new(0, 0, 1, 0)
			}
		):Play()

		task.spawn(function()
			-- Wait for the close tween to finish before hiding the frame fully
			task.wait(0.5)

			-- If the frame was removed while waiting, then it is no longer safe to change it
			if not Ammo_Frame or not Ammo_Frame.Parent then
				-- Return so the delayed code stops safely
				return
			end

			-- Force the closed size again after the tween
			Ammo_Frame.Size = UDim2.new(0, 0, 1, 0)

			-- Hide the frame after the close animation has finished
			Ammo_Frame.Visible = false
		end)
	end
end

function Framework.SetAmmo(ammo, maxammo, reserve, maxreserve)
	-- If no weapon is loaded, then there is no viewmodel gui to update
	if not Framework.Viewmodel then
		-- Return so the function does not try to use a missing viewmodel
		return
	end

	-- Update the ammo text on the current viewmodel
	update_ammo_gui(Framework.Viewmodel, ammo, maxammo)

	-- Make sure the ammo gui is visible after updating it
	set_ammo_gui_visible(Framework.Viewmodel, true)
end

function Framework.SetAmmoVisible(isvisible: boolean)
	-- If no weapon is loaded, then there is no ammo gui to show or hide
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- Apply the requested visible state to the ammo gui
	set_ammo_gui_visible(Framework.Viewmodel, isvisible)
end

function Framework.PreloadAnimations(item: string)
	-- Try to get the viewmodel folder from ReplicatedStorage
	local Models_Folder = ReplicatedStorage:FindFirstChild("Models")
	local Viewmodel_Folder = Models_Folder and Models_Folder:FindFirstChild("Viewmodels")

	-- If the viewmodel folder does not exist, then there is nothing to preload from
	if not Viewmodel_Folder then
		-- Return so the function stops safely
		return
	end

	-- Try to get the requested weapon viewmodel
	local Viewmodel = Viewmodel_Folder:FindFirstChild(item)

	-- If the requested weapon viewmodel does not exist, then there is nothing to preload
	if not Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- Try to get the Animations folder from the weapon viewmodel
	local Animation_Folder = Viewmodel:FindFirstChild("Animations")

	-- If the Animations folder is missing, then there are no animation assets to preload
	if not Animation_Folder then
		-- Return so the function stops safely
		return
	end

	local Assets = {}

	-- Loop through every descendant under the animation folder
	for _, Instance_Item in ipairs(Animation_Folder:GetDescendants()) do
		-- If the current descendant is an Animation object, then add it to the preload list
		if Instance_Item:IsA("Animation") then
			-- Insert the animation into the assets table so PreloadAsync can request it
			table.insert(Assets, Instance_Item)
		end
	end

	-- If there is at least one animation in the list, then preload them now
	if #Assets > 0 then
		-- Use pcall so a preload failure does not stop the whole module
		pcall(function()
			ContentProvider:PreloadAsync(Assets)
		end)
	end
end

function Framework.GetGunFrame(): Instance?
	-- If no viewmodel is loaded, then there is no gun frame to return
	if not Framework.Viewmodel then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Try to get the Gun object from the viewmodel
	local Gun = Framework.Viewmodel:FindFirstChild("Gun")

	-- If the Gun object is missing, then there is nothing valid to return
	if not Gun then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Return the Frame child if it exists, otherwise fall back to the Gun object itself
	return Gun:FindFirstChild("Frame") or Gun
end

function Framework.GetBarrelAttachment(): Attachment?
	-- If no viewmodel is loaded, then there is no barrel attachment to return
	if not Framework.Viewmodel then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Try to get the Gun object from the viewmodel
	local Gun = Framework.Viewmodel:FindFirstChild("Gun")

	-- If the Gun object is missing, then the barrel cannot be reached
	if not Gun then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Try to get the Barrel object from the Gun
	local Barrel = Gun:FindFirstChild("Barrel")

	-- If the Barrel object is missing, then there is no muzzle attachment to use
	if not Barrel then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Return the first Attachment found inside the barrel
	return Barrel:FindFirstChildWhichIsA("Attachment")
end

function Framework.PlaySfx(sfxname: string, parent: Instance?, settings: {Volume: number?, PlaybackSpeed: number?, TimePosition: number?, Lifetime: number?}?)
	-- If no viewmodel is loaded, then there is no SFX folder to read from
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- Try to get the SFX folder from the current viewmodel
	local Sfx_Folder = Framework.Viewmodel:FindFirstChild("SFX")

	-- If the SFX folder is missing, then this weapon has no sound templates to clone
	if not Sfx_Folder then
		-- Return so the function stops safely
		return
	end

	-- Try to get the requested sound template by name
	local Template = Sfx_Folder:FindFirstChild(sfxname)

	-- If the object does not exist, or exists but is not a Sound, then it cannot be played as audio
	if not Template or not Template:IsA("Sound") then
		-- Return so the function stops safely
		return
	end

	-- Clone the template so each play call gets its own sound instance
	local Sound = Template:Clone()

	-- Parent the sound to the requested object, or to the viewmodel if no parent was given
	Sound.Parent = parent or Framework.Viewmodel

	-- If settings were provided, then apply the overrides one by one
	if settings then
		-- If a volume override exists, then apply it to the cloned sound
		if settings.Volume ~= nil then
			Sound.Volume = settings.Volume
		end

		-- If a playback speed override exists, then apply it to the cloned sound
		if settings.PlaybackSpeed ~= nil then
			Sound.PlaybackSpeed = settings.PlaybackSpeed
		end

		-- If a start position override exists, then apply it to the cloned sound
		if settings.TimePosition ~= nil then
			Sound.TimePosition = settings.TimePosition
		end
	end

	-- Start playing the cloned sound now
	Sound:Play()

	-- Schedule the cloned sound for cleanup after its lifetime ends
	Debris:AddItem(Sound, (settings and settings.Lifetime) or 6)
end

function Framework.PlayMuzzleFlash()
	-- Try to get the barrel attachment used for muzzle effects
	local Attachment = Framework.GetBarrelAttachment()

	-- If no attachment exists, then there is nowhere to emit particles from
	if not Attachment then
		-- Return so the function stops safely
		return
	end

	-- Loop through every child under the attachment
	for _, Instance_Item in ipairs(Attachment:GetChildren()) do
		-- If the current child is a ParticleEmitter, then emit one burst from it
		if Instance_Item:IsA("ParticleEmitter") then
			Instance_Item:Emit(1)
		end
	end

	-- Try to get a PointLight from the same attachment
	local Flash_Light = Attachment:FindFirstChildWhichIsA("PointLight")

	-- If a PointLight exists, then flash it briefly for the muzzle light effect
	if Flash_Light then
		-- Turn the light on immediately
		Flash_Light.Enabled = true

		-- Save the original brightness so it can be restored later
		local Old_Brightness = Flash_Light.Brightness

		-- Randomize the brightness slightly so repeated shots feel less identical
		Flash_Light.Brightness = Old_Brightness * (0.85 + math.random() * 0.3)

		task.delay(0.06, function()
			-- If the light still exists, then it is safe to turn it back off now
			if Flash_Light and Flash_Light.Parent then
				-- Turn the light back off after the short flash
				Flash_Light.Enabled = false

				-- Restore the original brightness value
				Flash_Light.Brightness = Old_Brightness
			end
		end)
	end
end

-- Try to get the AnimationController from the current viewmodel
local function get_animation_controller(viewmodel: Model?): AnimationController?
	-- If there is no viewmodel, then there is no controller to return
	if not viewmodel then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Return the controller if it exists
	return viewmodel:FindFirstChild("AnimationController")
end

-- Try to get the Animator from the current viewmodel
local function get_animator(viewmodel: Model?): Animator?
	-- Ask the helper for the AnimationController first
	local Controller = get_animation_controller(viewmodel)

	-- If there is no controller, then there is nowhere to find or create an Animator
	if not Controller then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Try to find an existing Animator under the controller
	local Animator_Object = Controller:FindFirstChildOfClass("Animator")

	-- If an Animator already exists, then reuse it
	if Animator_Object then
		-- Return the existing Animator so the same object manages the tracks
		return Animator_Object
	end

	-- Create a new Animator if one was not found
	Animator_Object = Instance.new("Animator")

	-- Parent the new Animator to the controller so it can load tracks
	Animator_Object.Parent = Controller

	-- Return the newly created Animator
	return Animator_Object
end

-- Load one animation into a track through the Animator
local function load_track(viewmodel: Model?, animation: Animation?): AnimationTrack?
	-- If the viewmodel or animation is missing, then a track cannot be created
	if not viewmodel or not animation then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Try to get the Animator for this viewmodel
	local Animator_Object = get_animator(viewmodel)

	-- If the Animator could not be found or created, then the track cannot be loaded
	if not Animator_Object then
		-- Return nil so the caller can stop safely
		return nil
	end

	-- Load and return the animation track
	return Animator_Object:LoadAnimation(animation)
end

-- Stop every currently playing track except the one that should remain active
local function stop_all_except(excepttrack: AnimationTrack?, fadetime: number?)
	-- If there is no current viewmodel, then there are no tracks to stop
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- Try to get the Animator from the current viewmodel
	local Animator_Object = get_animator(Framework.Viewmodel)

	-- If no Animator exists, then there are no playing tracks to iterate through
	if not Animator_Object then
		-- Return so the function stops safely
		return
	end

	-- Loop through every track that is currently playing
	for _, Track in ipairs(Animator_Object:GetPlayingAnimationTracks()) do
		-- If this track is not the track we want to keep, then it should be stopped
		if Track ~= excepttrack then
			-- Stop the old track with the given fade time, or the default fade if none was provided
			Track:Stop(fadetime or Default_Fade)
		end
	end
end

function Framework._PlayTrack(track: AnimationTrack?, fadetime: number?, speed: number?)
	-- If no track was passed in, then there is nothing to play
	if not track then
		-- Return so the function stops safely
		return
	end

	-- Use the default fade time if the caller did not provide one
	fadetime = fadetime or Default_Fade

	-- If a custom speed was provided, then apply it before the track plays
	if speed then
		track:AdjustSpeed(speed)
	end

	-- Play the chosen track now
	track:Play(fadetime)

	-- Stop every other playing track so only the chosen track stays active
	stop_all_except(track, fadetime)
end

-- Recalculate movement animation from the Humanoid and camera direction
local function apply_move_from_humanoid(): boolean
	local Player = Players.LocalPlayer
	local Camera = workspace.CurrentCamera
	local Character = Player.Character

	-- If the character or camera is missing, then local movement direction cannot be calculated
	if not Character or not Camera then
		-- Return false so the caller knows movement could not be applied
		return false
	end

	-- Try to get the Humanoid from the character
	local Humanoid = Character:FindFirstChildOfClass("Humanoid")

	-- If the Humanoid is missing, then there is no movement vector to read
	if not Humanoid then
		-- Return false so the caller knows movement could not be applied
		return false
	end

	local Move_Direction = Humanoid.MoveDirection

	-- If the movement vector is extremely small, then treat that as not moving
	if Move_Direction.Magnitude < 0.05 then
		-- Return false so the caller can fall back to idle
		return false
	end

	-- Convert world movement into camera-local movement so first person movement animations match the view direction
	local Local_Direction = Camera.CFrame:VectorToObjectSpace(Move_Direction)

	local Direction: string

	-- If forward/backward influence is stronger than left/right influence,
	-- then choose a forward or backward animation
	if math.abs(Local_Direction.Z) >= math.abs(Local_Direction.X) then
		-- Use Forward when the local Z axis points forward, otherwise use Backward
		Direction = (Local_Direction.Z < 0) and "Forward" or "Backward"
	else
		-- If left/right influence is stronger, then choose a left or right animation
		Direction = (Local_Direction.X > 0) and "Right" or "Left"
	end

	-- Save the chosen movement state name
	Framework._current_state = "Move:" .. Direction

	-- Play the movement track that matches the chosen direction
	Framework._PlayTrack(Framework._tracks.Move and Framework._tracks.Move[Direction], Default_Fade)

	-- Return true so the caller knows movement was applied successfully
	return true
end

-- Start a new action token and return it
local function next_action_token(): number
	-- Increase the token because a newer action is starting now
	Framework._action_token += 1

	-- Return the new token so callbacks can compare against it later
	return Framework._action_token
end

-- Check whether a saved token still matches the current action
local function is_action_token_valid(token: number): boolean
	-- Return true only when the saved token still belongs to the newest action
	return token == Framework._action_token
end

-- Restore idle or movement after a one-shot action ends
local function restore_base_animation(token: number)
	-- If the saved token no longer matches the current token, then this callback is outdated
	if not is_action_token_valid(token) then
		-- Return so an old callback does not restore the wrong state
		return
	end

	-- If any one-shot action is still active, then it is too early to restore the base state
	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		-- Return so the active action can keep control of the viewmodel
		return
	end

	-- If movement is currently being held, then try to restore a movement animation
	if Framework._move_held then
		-- If movement could not be resolved from the Humanoid, then fall back to idle
		if not apply_move_from_humanoid() then
			Framework.Idle()
		end
	else
		-- If movement is not being held, then go back to idle directly
		Framework.Idle()
	end
end

function Framework._BuildTracks()
	-- If no viewmodel is loaded, then there is nothing to build tracks from
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- Try to get the Animations folder from the current viewmodel
	local Animation_Folder = Framework.Viewmodel:FindFirstChild("Animations")

	-- If the Animations folder is missing, then no tracks can be built
	if not Animation_Folder then
		-- Return so the function stops safely
		return
	end

	-- Clear the old track table before filling it with the new weapon tracks
	Framework._tracks = {}

	-- Try to get the Gun subfolder where one-shot gun actions are stored
	local Gun_Animation_Folder = Animation_Folder:FindFirstChild("Gun")

	-- If an Idle animation exists, then load it and configure it as a looped idle track
	if Animation_Folder:FindFirstChild("Idle") then
		-- Load the Idle track through the Animator
		Framework._tracks.Idle = load_track(Framework.Viewmodel, Animation_Folder.Idle)

		-- If the track loaded successfully, then configure its playback settings
		if Framework._tracks.Idle then
			Framework._tracks.Idle.Priority = Enum.AnimationPriority.Idle
			Framework._tracks.Idle.Looped = true
		end
	end

	-- If an Equip animation exists, then load it and configure it as a one-shot action
	if Animation_Folder:FindFirstChild("Equip") then
		-- Load the Equip track through the Animator
		Framework._tracks.Equip = load_track(Framework.Viewmodel, Animation_Folder.Equip)

		-- If the track loaded successfully, then configure its playback settings
		if Framework._tracks.Equip then
			Framework._tracks.Equip.Priority = Enum.AnimationPriority.Action
			Framework._tracks.Equip.Looped = false
		end
	end

	-- If the Gun animation folder exists, then try to load the optional one-shot gun tracks from it
	if Gun_Animation_Folder then
		-- If an Inspect animation exists, then load it
		if Gun_Animation_Folder:FindFirstChild("Inspect") then
			Framework._tracks.Inspect = load_track(Framework.Viewmodel, Gun_Animation_Folder.Inspect)

			-- If the track loaded successfully, then configure it as a one-shot action
			if Framework._tracks.Inspect then
				Framework._tracks.Inspect.Priority = Enum.AnimationPriority.Action
				Framework._tracks.Inspect.Looped = false
			end
		end

		-- If a Shoot animation exists, then load it
		if Gun_Animation_Folder:FindFirstChild("Shoot") then
			Framework._tracks.Shoot = load_track(Framework.Viewmodel, Gun_Animation_Folder.Shoot)

			-- If the track loaded successfully, then configure it as a one-shot action
			if Framework._tracks.Shoot then
				Framework._tracks.Shoot.Priority = Enum.AnimationPriority.Action
				Framework._tracks.Shoot.Looped = false
			end
		end

		-- If a Reload animation exists, then load it
		if Gun_Animation_Folder:FindFirstChild("Reload") then
			Framework._tracks.Reload = load_track(Framework.Viewmodel, Gun_Animation_Folder.Reload)

			-- If the track loaded successfully, then configure it as a one-shot action
			if Framework._tracks.Reload then
				Framework._tracks.Reload.Priority = Enum.AnimationPriority.Action
				Framework._tracks.Reload.Looped = false
			end
		end
	end

	-- Create the movement track table even if some directions are missing
	Framework._tracks.Move = {}

	-- Try to get the Movement folder from the animation set
	local Move_Folder = Animation_Folder:FindFirstChild("Movement")

	-- If the Movement folder exists, then iterate through each expected direction name
	if Move_Folder then
		for _, Direction_Name in ipairs({"Forward", "Backward", "Left", "Right"}) do
			-- If the current direction animation exists, then load that one
			if Move_Folder:FindFirstChild(Direction_Name) then
				local Track = load_track(Framework.Viewmodel, Move_Folder[Direction_Name])

				-- If the track loaded successfully, then configure and store it
				if Track then
					Track.Priority = Enum.AnimationPriority.Movement
					Track.Looped = true
					Framework._tracks.Move[Direction_Name] = Track
				end
			end
		end
	end
end

function Framework.ClearSlot()
	local Camera = workspace.CurrentCamera

	-- If the camera exists, then remove any old weapon models parented to it
	if Camera then
		for _, Child in pairs(Camera:GetChildren()) do
			-- If this child is a Model, then it is treated as a first person viewmodel and destroyed
			if Child:IsA("Model") then
				Child:Destroy()
			end
		end
	end

	-- If the equip connection exists, then disconnect it now so old callbacks cannot fire later
	if Framework._equip_conn then
		Framework._equip_conn:Disconnect()
		Framework._equip_conn = nil
	end

	-- If the inspect connection exists, then disconnect it now so old callbacks cannot fire later
	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
		Framework._inspect_conn = nil
	end

	-- If the shoot connection exists, then disconnect it now so old callbacks cannot fire later
	if Framework._shoot_conn then
		Framework._shoot_conn:Disconnect()
		Framework._shoot_conn = nil
	end

	-- If the reload connection exists, then disconnect it now so old callbacks cannot fire later
	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
		Framework._reload_conn = nil
	end

	-- Reset all action flags because the old weapon slot is gone
	Framework._equip_playing = false
	Framework._inspect_playing = false
	Framework._shoot_playing = false
	Framework._reload_playing = false
	Framework._weapon_locked = false

	-- Reset the token so old action callbacks no longer belong to a live weapon state
	Framework._action_token = 0

	-- Clear all stored references and temporary state from the previous slot
	Framework.Viewmodel = nil
	Framework.Module = nil
	Framework._tracks = {}
	Framework._current_state = nil
	Framework._move_held = false

	-- Reset sway state so the next weapon starts cleanly
	Framework._last_camera_cframe = nil
	Framework._sway_rot = CFrame.new()
	Framework._sway_pos = Vector3.new()
end

function Framework.Idle()
	-- Mark movement as not held when switching directly into idle
	Framework._move_held = false

	-- If no viewmodel is loaded, then there is no idle track to play
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- If any one-shot action is active, then idle should not interrupt it
	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		-- Return so the active action keeps control
		return
	end

	-- If the current state is already idle, then do not replay idle again
	if Framework._current_state == "Idle" then
		-- Return so the same state is not restarted unnecessarily
		return
	end

	-- Save the new state name
	Framework._current_state = "Idle"

	-- Play the idle track
	Framework._PlayTrack(Framework._tracks.Idle, Default_Fade)
end

function Framework.Movement(key: Enum.KeyCode)
	-- Mark movement as held because this function is called from movement input
	Framework._move_held = true

	-- If no viewmodel is loaded, then there is no movement track to play
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- If any one-shot action is active, then movement should not replace it
	if Framework._equip_playing or Framework._inspect_playing or Framework._shoot_playing or Framework._reload_playing then
		-- Return so the active action keeps control
		return
	end

	local Direction: string? = nil

	-- If the key is W, then choose the Forward movement animation
	if key == Enum.KeyCode.W then
		Direction = "Forward"
	-- If the key is S, then choose the Backward movement animation
	elseif key == Enum.KeyCode.S then
		Direction = "Backward"
	-- If the key is D, then choose the Right movement animation
	elseif key == Enum.KeyCode.D then
		Direction = "Right"
	-- If the key is A, then choose the Left movement animation
	elseif key == Enum.KeyCode.A then
		Direction = "Left"
	end

	-- If none of the supported movement keys matched, then there is no direction to play
	if not Direction then
		-- Return so the function stops safely
		return
	end

	-- Save the new state name
	Framework._current_state = "Move:" .. Direction

	-- Play the movement track for the chosen direction
	Framework._PlayTrack(Framework._tracks.Move and Framework._tracks.Move[Direction], Default_Fade)
end

function Framework.Inspect()
	-- If no viewmodel is loaded, then there is nothing to inspect
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- If equip is still playing, then inspect must not start yet
	if Framework._equip_playing then
		-- Return so equip can finish first
		return
	end

	-- If inspect is already playing, then do not start another inspect on top of it
	if Framework._inspect_playing then
		-- Return so the current inspect can continue
		return
	end

	-- If this weapon has no inspect track, then there is no inspect animation to play
	if not Framework._tracks.Inspect then
		-- Return so the function stops safely
		return
	end

	-- Start a fresh token for this inspect action
	local Action_Token = next_action_token()

	-- Mark inspect as active and lock the weapon while the action runs
	Framework._inspect_playing = true
	Framework._weapon_locked = true

	-- Save the current state name
	Framework._current_state = "Inspect"

	-- Play the inspect track now
	Framework._PlayTrack(Framework._tracks.Inspect, Default_Fade)

	-- If the weapon module has custom inspect logic, then run it now
	if Framework.Module and Framework.Module.ClientInspect then
		Framework.Module.ClientInspect(Framework)
	end

	-- Hide the ammo gui during inspect
	set_ammo_gui_visible(Framework.Viewmodel, false)

	-- If an old inspect callback connection exists, then disconnect it before creating a new one
	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
	end

	-- Listen for the inspect track stopping so the base state can be restored afterwards
	Framework._inspect_conn = Framework._tracks.Inspect.Stopped:Connect(function()
		-- Mark inspect as no longer active
		Framework._inspect_playing = false

		-- If this callback belongs to an older action, then it must not change the current state
		if not is_action_token_valid(Action_Token) then
			-- Return so an old callback does not restore the wrong animation state
			return
		end

		-- Unlock the weapon now that inspect has ended
		Framework._weapon_locked = false

		-- Show the ammo gui again after inspect finishes
		set_ammo_gui_visible(Framework.Viewmodel, true)

		-- Restore movement or idle after inspect has finished
		restore_base_animation(Action_Token)
	end)
end

function Framework.CancelInspect()
	-- If inspect is not active, then there is nothing to cancel
	if not Framework._inspect_playing then
		-- Return so the function stops safely
		return
	end

	-- Start a new token so the old inspect callback becomes outdated
	next_action_token()

	-- Mark inspect as no longer active and unlock the weapon immediately
	Framework._inspect_playing = false
	Framework._weapon_locked = false

	-- Show the ammo gui again because inspect is being cancelled
	set_ammo_gui_visible(Framework.Viewmodel, true)

	-- If the inspect callback connection exists, then disconnect it now
	if Framework._inspect_conn then
		Framework._inspect_conn:Disconnect()
		Framework._inspect_conn = nil
	end

	-- If the inspect track exists, then stop it immediately
	if Framework._tracks.Inspect then
		pcall(function()
			Framework._tracks.Inspect:Stop(0)
		end)
	end

	-- If the weapon module has custom inspect cancel logic, then run it now
	if Framework.Module and Framework.Module.ClientCancelInspect then
		Framework.Module.ClientCancelInspect(Framework)
	end

	-- Restore movement or idle after the cancel
	restore_base_animation(Framework._action_token)
end

function Framework.Shoot()
	-- If no viewmodel is loaded, then there is no shoot track to play
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- If equip is still playing, then shooting must not start yet
	if Framework._equip_playing then
		-- Return so equip keeps control
		return
	end

	-- If this weapon has no shoot track, then there is nothing to play here
	if not Framework._tracks.Shoot then
		-- Return so the function stops safely
		return
	end

	-- Start a fresh token for this shoot action
	local Action_Token = next_action_token()

	-- Mark shoot as active and lock the weapon while the action runs
	Framework._weapon_locked = true
	Framework._shoot_playing = true

	-- Save the current state name
	Framework._current_state = "Shoot"

	-- Play the shoot track now
	Framework._PlayTrack(Framework._tracks.Shoot, Default_Fade)

	-- If the weapon module has custom shoot logic, then run it now
	if Framework.Module and Framework.Module.ClientShoot then
		Framework.Module.ClientShoot(Framework)
	end

	-- If an old shoot callback connection exists, then disconnect it before creating a new one
	if Framework._shoot_conn then
		Framework._shoot_conn:Disconnect()
	end

	-- Listen for the shoot track stopping so the base state can be restored afterwards
	Framework._shoot_conn = Framework._tracks.Shoot.Stopped:Connect(function()
		-- Mark shoot as no longer active
		Framework._shoot_playing = false

		-- If this callback belongs to an older action, then it must not change the current state
		if not is_action_token_valid(Action_Token) then
			-- Return so an old callback does not restore the wrong animation state
			return
		end

		-- Unlock the weapon now that shoot has ended
		Framework._weapon_locked = false

		-- Restore movement or idle after shoot has finished
		restore_base_animation(Action_Token)
	end)
end

function Framework.Reload()
	-- If no viewmodel is loaded, then there is no reload track to play
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- If equip is still playing, then reload must not start yet
	if Framework._equip_playing then
		-- Return so equip keeps control
		return
	end

	-- If this weapon has no reload track, then there is nothing to play here
	if not Framework._tracks.Reload then
		-- Return so the function stops safely
		return
	end

	-- Start a fresh token for this reload action
	local Action_Token = next_action_token()

	-- Mark reload as active and lock the weapon while the action runs
	Framework._weapon_locked = true
	Framework._reload_playing = true

	-- Save the current state name
	Framework._current_state = "Reload"

	-- Play the reload track now
	Framework._PlayTrack(Framework._tracks.Reload, Default_Fade)

	-- Hide the ammo gui during reload
	set_ammo_gui_visible(Framework.Viewmodel, false)

	-- If the weapon module has custom reload logic, then run it now
	if Framework.Module and Framework.Module.ClientReload then
		Framework.Module.ClientReload(Framework)
	end

	-- If an old reload callback connection exists, then disconnect it before creating a new one
	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
	end

	-- Listen for the reload track stopping so the base state can be restored afterwards
	Framework._reload_conn = Framework._tracks.Reload.Stopped:Connect(function()
		-- Mark reload as no longer active
		Framework._reload_playing = false

		-- If this callback belongs to an older action, then it must not change the current state
		if not is_action_token_valid(Action_Token) then
			-- Return so an old callback does not restore the wrong animation state
			return
		end

		-- Unlock the weapon now that reload has ended
		Framework._weapon_locked = false

		-- Show the ammo gui again after reload finishes
		set_ammo_gui_visible(Framework.Viewmodel, true)

		-- Restore movement or idle after reload has finished
		restore_base_animation(Action_Token)
	end)
end

function Framework.CancelReload()
	-- If reload is not active, then there is nothing to cancel
	if not Framework._reload_playing then
		-- Return so the function stops safely
		return
	end

	-- Start a new token so the old reload callback becomes outdated
	next_action_token()

	-- Mark reload as no longer active and unlock the weapon immediately
	Framework._reload_playing = false
	Framework._weapon_locked = false

	-- If the reload callback connection exists, then disconnect it now
	if Framework._reload_conn then
		Framework._reload_conn:Disconnect()
		Framework._reload_conn = nil
	end

	-- If the reload track exists, then stop it immediately
	if Framework._tracks.Reload then
		pcall(function()
			Framework._tracks.Reload:Stop(0)
		end)
	end

	-- If the weapon module has custom reload cancel logic, then run it now
	if Framework.Module and Framework.Module.ClientCancelReload then
		Framework.Module.ClientCancelReload(Framework)
	end

	-- Show the ammo gui again because reload is being cancelled
	set_ammo_gui_visible(Framework.Viewmodel, true)

	-- Restore movement or idle after the cancel
	restore_base_animation(Framework._action_token)
end

function Framework.Dry()
	-- If no viewmodel is loaded, then there is no local dry fire state to play from
	if not Framework.Viewmodel then
		-- Return so the function stops safely
		return
	end

	-- If equip is still playing, then dry fire must not start yet
	if Framework._equip_playing then
		-- Return so equip keeps control
		return
	end

	-- If the weapon module has custom dry fire logic, then run that and stop here
	if Framework.Module and Framework.Module.ClientDry then
		Framework.Module.ClientDry(Framework)
		return
	end

	-- If no custom handler exists, then play the default dry click sound
	Framework.PlaySfx("DryClick", Framework.GetGunFrame() or Framework.Viewmodel, {Lifetime = 4})
end

local function render_tracer(origin: Vector3, endpos: Vector3)
	local Delta = endpos - origin
	local Distance = Delta.Magnitude

	-- If the tracer would be too short, then skip it because it would not be visible anyway
	if Distance < 0.2 then
		-- Return so no unnecessary part gets created
		return
	end

	-- If the tracer would be too long, then clamp it to a safe max distance
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

	-- Remove the tracer shortly after creating it
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

	-- Remove the impact helper part shortly after creating it
	Debris:AddItem(Part, 0.08)
end

function Framework.RenderShotFX(shooterplayer: Player, weaponname: string, origin: Vector3, dir: Vector3, endpos: Vector3, hit: any)
	-- If both origin and end position are valid Vector3 values, then render the tracer
	if typeof(origin) == "Vector3" and typeof(endpos) == "Vector3" then
		render_tracer(origin, endpos)
	end

	-- If the caller says the shot hit something, then render the impact light
	if hit == true then
		render_impact(endpos)
	end
end

function Framework.StepViewmodel(cameracframe: CFrame, dt: number)
	-- If no viewmodel is loaded, then just cache the camera and stop here
	if not Framework.Viewmodel then
		Framework._last_camera_cframe = cameracframe
		return
	end

	-- Try to get the Camera part from the current viewmodel
	local Camera_Part = Framework.Viewmodel:FindFirstChild("Camera")

	-- If the Camera part is missing, or exists but is not a BasePart,
	-- then sway cannot be applied safely
	if not Camera_Part or not Camera_Part:IsA("BasePart") then
		Framework._last_camera_cframe = cameracframe
		return
	end

	-- If sway is disabled, then keep the viewmodel camera part exactly on the real camera transform
	if not Framework.Sway.Enabled then
		Camera_Part.CFrame = cameracframe
		Framework._last_camera_cframe = cameracframe
		return
	end

	-- If there is no previous camera transform yet, then cache this frame and place the camera part directly
	if not Framework._last_camera_cframe then
		Framework._last_camera_cframe = cameracframe
		Camera_Part.CFrame = cameracframe
		return
	end

	-- Measure how the camera moved since the previous frame
	local Delta = Framework._last_camera_cframe:ToObjectSpace(cameracframe)
	local Pitch, Yaw, Roll = Delta:ToOrientation()

	-- Convert the camera delta into target sway rotation values
	local Target_Rot_X = math.clamp(-Pitch * Framework.Sway.RotMultiplier, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)
	local Target_Rot_Y = math.clamp(-Yaw * Framework.Sway.RotMultiplier, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)
	local Target_Roll = math.clamp(-Roll * 0.25, -Framework.Sway.MaxRot, Framework.Sway.MaxRot)

	local Target_Rotation = CFrame.Angles(Target_Rot_X, Target_Rot_Y, Target_Roll)

	-- Convert the same camera delta into target sway position values
	local Target_Position = Vector3.new(
		math.clamp(-Yaw * Framework.Sway.PosMultiplier, -Framework.Sway.MaxPos, Framework.Sway.MaxPos),
		math.clamp(-Pitch * Framework.Sway.PosMultiplier, -Framework.Sway.MaxPos, Framework.Sway.MaxPos),
		0
	)

	-- Calculate smoothing values from delta time
	local Follow_Alpha = 1 - math.exp(-dt * Framework.Sway.FollowSpeed)
	local Return_Alpha = 1 - math.exp(-dt * Framework.Sway.ReturnSpeed)

	-- Smoothly move the sway position toward the target position
	Framework._sway_pos = Framework._sway_pos:Lerp(Target_Position, Follow_Alpha)

	-- Smoothly move the sway rotation toward the target rotation
	Framework._sway_rot = Framework._sway_rot:Lerp(Target_Rotation, Return_Alpha)

	-- Apply the smoothed sway to the viewmodel camera part
	Camera_Part.CFrame = cameracframe * CFrame.new(Framework._sway_pos) * Framework._sway_rot

	-- Cache this frame's camera transform for the next update
	Framework._last_camera_cframe = cameracframe
end

function Framework.LoadSlot(item: string)
	-- Clear the old weapon slot first so the new one starts from a clean state
	Framework.ClearSlot()

	local Player = Players.LocalPlayer
	local Character = Player.Character
	local Camera = workspace.CurrentCamera

	-- If the character or camera is missing, then the new slot cannot be loaded safely
	if not Character or not Camera then
		-- Return so the function stops safely
		return
	end

	-- Try to get the folders used for weapon models and optional weapon modules
	local Models_Folder = ReplicatedStorage:FindFirstChild("Models")
	local Viewmodel_Folder = Models_Folder and Models_Folder:FindFirstChild("Viewmodels")
	local Modules_Folder = ReplicatedStorage:FindFirstChild("Modules")
	local Framework_Folder = Modules_Folder and Modules_Folder:FindFirstChild("Framework")

	-- If the requested weapon module exists, then require it and store it
	if Framework_Folder and Framework_Folder:FindFirstChild(item) then
		Framework.Module = require(Framework_Folder[item])
	else
		-- If no matching weapon module exists, then store nil instead
		Framework.Module = nil
	end

	-- If the requested weapon viewmodel exists, then clone it into the camera
	if Viewmodel_Folder and Viewmodel_Folder:FindFirstChild(item) then
		Framework.Viewmodel = Viewmodel_Folder[item]:Clone()
		Framework.Viewmodel.Parent = Camera
	else
		-- If the requested viewmodel does not exist, then stop here
		return
	end

	-- If both the first person right arm and the character right arm exist,
	-- then copy the character arm color into the viewmodel arm
	if Framework.Viewmodel:FindFirstChild("RightArm") and Character:FindFirstChild("Right Arm") then
		Framework.Viewmodel.RightArm.Color = Character["Right Arm"].Color
	end

	-- If both the first person left arm and the character left arm exist,
	-- then copy the character arm color into the viewmodel arm
	if Framework.Viewmodel:FindFirstChild("LeftArm") and Character:FindFirstChild("Left Arm") then
		Framework.Viewmodel.LeftArm.Color = Character["Left Arm"].Color
	end

	-- Build the animation tracks for the newly loaded weapon
	Framework._BuildTracks()

	do
		local Humanoid = Character:FindFirstChildOfClass("Humanoid")

		-- If the player is already moving when the weapon is loaded,
		-- then remember that so the module can return to movement later
		Framework._move_held = (Humanoid and Humanoid.MoveDirection.Magnitude > 0.05) and true or false
	end

	-- If an Equip track exists, then start the weapon in the equip state
	if Framework._tracks.Equip then
		local Action_Token = next_action_token()

		Framework._equip_playing = true
		Framework._weapon_locked = true

		Framework._current_state = "Equip"
		Framework._PlayTrack(Framework._tracks.Equip, Default_Fade)

		-- If the weapon module has custom equip logic, then run it now
		if Framework.Module and Framework.Module.ClientEquip then
			Framework.Module.ClientEquip(Framework)
		else
			-- If there is no custom equip logic, then play the default equip sound
			Framework.PlaySfx("Equip", Framework.GetGunFrame() or Framework.Viewmodel, {Lifetime = 4})
		end

		-- If an old equip callback connection exists, then disconnect it before creating a new one
		if Framework._equip_conn then
			Framework._equip_conn:Disconnect()
		end

		-- Listen for the equip track stopping so the base state can be restored afterwards
		Framework._equip_conn = Framework._tracks.Equip.Stopped:Connect(function()
			-- If the viewmodel was cleared while equip was playing, then stop here
			if not Framework.Viewmodel then
				return
			end

			-- Mark equip as no longer active
			Framework._equip_playing = false

			-- If this callback belongs to an older action, then it must not change the current state
			if not is_action_token_valid(Action_Token) then
				-- Return so an old callback does not restore the wrong animation state
				return
			end

			-- Unlock the weapon now that equip has ended
			Framework._weapon_locked = false

			-- Restore movement or idle after equip has finished
			restore_base_animation(Action_Token)
		end)
	else
		-- If there is no Equip track, then go straight into the base state
		Framework._equip_playing = false
		Framework._weapon_locked = false
		Framework.Idle()
		set_ammo_gui_visible(Framework.Viewmodel, true)
	end
end

return Framework
