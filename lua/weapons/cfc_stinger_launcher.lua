AddCSLuaFile()

SWEP.Category           = "CFC"
SWEP.PrintName          = "Stinger Missile"
SWEP.Author             = "CFC"
SWEP.Instructions       = "Homing, anti-air RPG.\nFor best results, use on distant targets."
SWEP.Slot               = 4
SWEP.SlotPos            = 9

SWEP.Spawnable          = true
SWEP.AdminSpawnable     = false
SWEP.ViewModel          = "models/weapons/c_rpg.mdl"
SWEP.WorldModel         = "models/weapons/w_rocket_launcher.mdl"
SWEP.UseHands           = true
SWEP.ViewModelFlip      = false
SWEP.ViewModelFOV       = 53
SWEP.Weight             = 42
SWEP.AutoSwitchTo       = true
SWEP.AutoSwitchFrom     = true
SWEP.HoldType           = "rpg"

SWEP.Primary.ClipSize        = 1
SWEP.Primary.DefaultClip     = 1
SWEP.Primary.Automatic       = false
SWEP.Primary.Ammo1           = "RPG_Round"

SWEP.Secondary.ClipSize      = -1
SWEP.Secondary.DefaultClip   = -1
SWEP.Secondary.Automatic     = false
SWEP.Secondary.Ammo          = "none"

SWEP.ReloadSpeedMul = 0.45
SWEP.UnmodReloadTime = 1.8 -- rough estimate of unmodified reload time

if CLIENT then
    SWEP.BounceWeaponIcon = false
    SWEP.WepSelectIcon = surface.GetTextureID( "vgui/hud/cfc_stinger_launcher_wepselecticon" )
end

SWEP.CFC_FirstTimeHints = {
    {
        Message = "This is a homing, anti-air RPG",
        Sound = "ambient/water/drip1.wav",
        Duration = 8,
        DelayNext = 7,
    },
    {
        Message = "Aim at a vehicle, and FIRE when the reticle turns red!",
        Sound = "ambient/water/drip2.wav",
        Duration = 15,
        DelayNext = 0,
    },
}

function SWEP:SetupDataTables()
    self:NetworkVar( "Entity", 0, "ClosestEnt" )
    self:NetworkVar( "Bool", 0, "IsLocked" )
    self:NetworkVar( "Float", 0, "LockedOnTime" )
end

function SWEP:Initialize()
    self:SetHoldType( self.HoldType )
end

local stingerLockTime = CreateConVar( "cfc_stinger_locktime", 4, { FCVAR_ARCHIVE, FCVAR_REPLICATED } )
local stingerLockAngle

if SERVER then
    stingerLockAngle = CreateConVar( "cfc_stinger_lockangle", 7, FCVAR_ARCHIVE )

    local maxRange = CreateConVar( "cfc_stinger_maxrange", 60000, { FCVAR_ARCHIVE } ):GetInt()
    SetGlobalInt( "cfc_stinger_maxrange", maxRange )

    cvars.AddChangeCallback( "cfc_stinger_maxrange", function( _, _, value )
        SetGlobalInt( "cfc_stinger_maxrange", tonumber( value ) )
        maxRange = tonumber( value )
    end, "CFC_Stinger_Range" )

    local function setFogRange()
        local fogController = ents.FindByClass( "env_fog_controller" )[1]
        if not IsValid( fogController ) then return end

        local fogRange = fogController:GetKeyValues().farz
        if fogRange == -1 then return end
        SetGlobalInt( "cfc_stinger_maxrange", math.min( maxRange, fogRange ) )
    end

    hook.Add( "InitPostEntity", "CFC_Stinger_Range", setFogRange )
    setFogRange() -- Autorefresh
end

function SWEP:GetPotentialTargets()
    local foundVehicles = {}
    local addedAlready = {}

    for _, vehicle in ipairs( ents.FindByClass( "npc_helicopter" ) ) do
        table.insert( foundVehicles, vehicle )
    end

    for _, vehicle in ipairs( ents.FindByClass( "npc_combinegunship" ) ) do
        table.insert( foundVehicles, vehicle )
    end

    for _, vehicle in ipairs( ents.FindByClass( "npc_combinedropship" ) ) do
        table.insert( foundVehicles, vehicle )
    end

    for _, vehicle in ipairs( ents.FindByClass( "prop_vehicle_*" ) ) do
        local vechiclesDriver = vehicle:GetDriver()
        if IsValid( vechiclesDriver ) then
            local parent = vehicle:GetParent()
            if parent:IsVehicle() and parent:GetDriver() == vehiclesDriver and not addedAlready[parent] then -- glide/simfphys
                table.insert( foundVehicles, parent )
                addedAlready[parent] = true
                addedAlready[vehicle] = true
            else
                table.insert( foundVehicles, vehicle )
            end
        end
    end
    return foundVehicles
end

function SWEP:Think()
    if CLIENT then return end

    self.nextSortTargets = self.nextSortTargets or 0
    self.findTime = self.findTime or 0
    self.nextFind = self.nextFind or 0

    local curtime = CurTime()
    local owner = self:GetOwner()
    local findTime = self.findTime
    local lockOnTime = stingerLockTime:GetFloat()

    if findTime + lockOnTime < curtime and IsValid( self:GetClosestEnt() ) then
        self.Locked = true
    else
        self.Locked = false
    end

    if self.Locked ~= self:GetIsLocked() then
        self:SetIsLocked( self.Locked )

        if self.Locked then
            self.LockSND = CreateSound( owner, "weapons/cfc_stinger/radar_lock.wav" )
            self.LockSND:PlayEx( 0.5, 100 )

            if self.TrackSND then
                self.TrackSND:Stop()
                self.TrackSND = nil
            end
        else
            if self.LockSND then
                self.LockSND:Stop()
                self.LockSND = nil
            end
        end
    end

    if self.nextFind < curtime then
        self.nextFind = curtime + 3
        self.foundVehicles = self:GetPotentialTargets()
    end

    if self:Clip1() <= 0 then
        self:SetClosestEnt( nil )
        if self.TrackSND then
            self.TrackSND:Stop()
            self.TrackSND = nil
        end

    elseif self.nextSortTargets < curtime then
        self.nextSortTargets = curtime + 0.25
        self.foundVehicles = self.foundVehicles or {}

        local AimForward = owner:GetAimVector()
        local startpos = owner:GetShootPos()

        local maxDist = GetGlobalInt( "cfc_stinger_maxrange" )
        local lockOnAng = stingerLockAngle:GetInt()

        local vehicles = {}
        local closestEnt = NULL
        local closestDist = math.huge
        local smallestAng = math.huge

        for index, vehicle in pairs( self.foundVehicles ) do
            if not IsValid( vehicle ) then table.remove( self.foundVehicles, index ) continue end

            local hookResult = hook.Run( "CFC_Stinger_BlockLockon", self, vehicle )
            if hookResult == true then table.remove( self.foundVehicles, index ) continue end

            local sub = ( vehicle:GetPos() - startpos )
            local toEnt = sub:GetNormalized()
            local ang = math.acos( math.Clamp( AimForward:Dot( toEnt ), -1, 1 ) ) * ( 180 / math.pi )

            if ang >= lockOnAng or not self:CanSee( vehicle, owner ) then continue end

            table.insert( vehicles, vehicle )

            local stuff = WorldToLocal( vehicle:GetPos(), Angle( 0, 0, 0 ), startpos, owner:EyeAngles() + Angle( 90, 0, 0 ) )
            local dist = stuff:Length()

            if dist > maxDist then continue end

             -- only switch when much closer!
            if dist < closestDist and ang < smallestAng then
                closestDist = dist
                smallestAng = ang
                if closestEnt ~= vehicle then
                    closestEnt = vehicle
                end
            end
        end

        local entInSights = IsValid( closestEnt )
        local anOldEntInSights = IsValid( self:GetClosestEnt() )
        local lockingOnForOneFourthOfLockOnTime = ( findTime + ( lockOnTime / 4 ) ) < curtime
        local lockingOnBlockSwitching = lockingOnForOneFourthOfLockOnTime and anOldEntInSights and entInSights

        -- switch targets when not locking onto a target for more than 1/4th of the lockOnTime
        -- stops the rpg switching between really close targets, eg bunch of people in a simfphys, prop car, prop helicopter.
        if self:GetClosestEnt() ~= closestEnt and not lockingOnBlockSwitching then
            self:SetClosestEnt( closestEnt )

            if IsValid( closestEnt ) then
                self.findTime = curtime
                self:SetLockedOnTime( curtime + lockOnTime )
                self.TrackSND = CreateSound( owner, "weapons/cfc_stinger/radar_track.wav" )
                self.TrackSND:PlayEx( 0, 100 )
                self.TrackSND:ChangeVolume( 0.5, 2 )
            elseif self.TrackSND then
                self.TrackSND:Stop()
                self.TrackSND = nil
            end
        end

        if IsValid( closestEnt ) and Glide then
            if closestEnt.IsGlideVehicle then
                -- If the target is a Glide vehicle, notify the passengers
                Glide.SendLockOnDanger( closestEnt:GetAllPlayers() )

            elseif closestEnt.GetDriver then
                -- If the target is another type of vehicle, notify the driver
                local driver = closestEnt:GetDriver()

                if IsValid( driver ) then
                    Glide.SendLockOnDanger( driver )
                end
            end
        end

        if not IsValid( closestEnt ) and self.TrackSND then
            self.TrackSND:Stop()
            self.TrackSND = nil
        end
    end
end

function SWEP:CanSee( entity, owner )
    local pos = entity:GetPos()

    owner = owner or self:GetOwner()

    local trStruc = {
        start = owner:GetShootPos(),
        endpos = pos,
        filter = owner,
    }

    local trResult = util.TraceLine( trStruc )
    return ( trResult.HitPos - pos ):Length() < 500
end

function SWEP:PrimaryAttack()
    if SERVER and self:Clip1() <= 0 then
        self:Reload()
    end

    if not self:CanPrimaryAttack() then return end

    self:SetNextPrimaryFire( CurTime() + 0.5 )
    self:TakePrimaryAmmo( 1 )

    local owner = self:GetOwner()

    owner:ViewPunch( Angle( -10, -5, 0 ) )

    if CLIENT then return end

    local startpos = owner:GetShootPos() + owner:EyeAngles():Right() * 10
    local ent = ents.Create( "cfc_stinger_missile" )
    ent:SetPos( startpos )
    ent:SetAngles( ( owner:GetEyeTrace().HitPos - startpos ):Angle() )
    ent:SetOwner( owner )
    ent.Attacker = owner
    ent:Spawn()
    ent:Activate()

    ent:SetAttacker( owner )
    ent:SetInflictor( owner:GetActiveWeapon() )

    ent:EmitSound( "weapons/stinger_fire1.wav", 100, math.random( 80, 90 ), 1, CHAN_WEAPON )
    owner:EmitSound( "Weapon_RPG.NPC_Single" )

    util.ScreenShake( owner:GetShootPos(), 20, 20, 0.15, 800 )
    util.ScreenShake( owner:GetShootPos(), 1, 20, 3, 1500 )

    local lockOnTarget = self:GetClosestEnt()

    if IsValid( lockOnTarget ) and self:GetIsLocked() then
        ent:SetLockOn( lockOnTarget )
    end

    if SERVER then
        timer.Simple( 0, function() -- fix rare anim bug
            if not IsValid( self ) then return end
            if self:Clip1() > 0 then return end
            self:Reload()
        end )
    end
end

function SWEP:SecondaryAttack()
    if not IsValid( self:GetClosestEnt() ) then return false end
    if not IsFirstTimePredicted() then return end
    self:SetNextSecondaryFire( CurTime() + 0.5 )
    if CLIENT then
        self:EmitSound( "buttons/lightswitch2.wav", 75, math.random( 150, 175 ), 0.25 )
    else
        self:UnLock()
    end
end

function SWEP:Deploy()
    self:SendWeaponAnim( ACT_VM_DRAW )
    return true
end

function SWEP:Reload()
    if self:Clip1() > 0 or self:GetOwner():GetAmmoCount( self.Primary.Ammo ) <= 0 then return end
    self:UnLock()
    self:DefaultReload( ACT_VM_RELOAD )

    local reloadSpeedMul = self.ReloadSpeedMul
    local unmodReloadTime = self.UnmodReloadTime -- match the slower anim

    local nextFire = CurTime() + ( unmodReloadTime / reloadSpeedMul )
    self:SetNextPrimaryFire( nextFire )

    local owner = self:GetOwner()
    local vm = owner:GetViewModel()
    if IsValid( vm ) then
        vm:SetPlaybackRate( reloadSpeedMul ) -- slower anim

    end
end

function SWEP:UnLock()
    self:StopSounds()
end

function SWEP:StopSounds()
    if self.TrackSND then
        self.TrackSND:Stop()
        self.TrackSND = nil
    end

    if self.LockSND then
        self.LockSND:Stop()
        self.LockSND = nil
    end

    self:SetClosestEnt( NULL )
    self:SetIsLocked( false )
end

function SWEP:Holster()
    self:StopSounds()
    return true
end

function SWEP:OnDrop()
    self:StopSounds()
end

function SWEP:OwnerChanged()
    self:StopSounds()
end

if not CLIENT then return end

local notLockedSize = 100
local lockedSize = 30
local difference = notLockedSize - lockedSize

function SWEP:DrawHUD()
    local ply = LocalPlayer()

    if ply:InVehicle() then return end

    local ent = self:GetClosestEnt()

    if not IsValid( ent ) then return end

    local pos = ent:LocalToWorld( ent:OBBCenter() )

    local scr = pos:ToScreen()
    local scrWH = ScrW() / 2
    local scrHH = ScrH() / 2

    local posX = scr.x
    local posY = scr.y

    draw.NoTexture()
    if self:GetIsLocked() then
        surface.SetDrawColor( 200, 0, 0, 255 )
    else
        surface.SetDrawColor( 200, 200, 200, 255 )
    end

    surface.DrawLine( scrWH, scrHH, posX, posY )

    local size = 0
    if self:GetIsLocked() then
        size = lockedSize

    else
        local untilLocked = self:GetLockedOnTime() - CurTime()
        local normalized = untilLocked / stingerLockTime:GetFloat()
        size = math.Clamp( lockedSize + ( normalized * difference ), lockedSize, notLockedSize )

    end

    surface.DrawLine( posX - size, posY + size, posX - size * 0.5, posY + size )
    surface.DrawLine( posX + size, posY + size, posX + size * 0.5, posY + size )

    surface.DrawLine( posX - size, posY + size, posX - size, posY + size * 0.5 )
    surface.DrawLine( posX - size, posY - size, posX - size, posY - size * 0.5 )

    surface.DrawLine( posX + size, posY + size, posX + size, posY + size * 0.5 )
    surface.DrawLine( posX + size, posY - size, posX + size, posY - size * 0.5 )

    surface.DrawLine( posX - size, posY - size, posX - size * 0.5, posY - size )
    surface.DrawLine( posX + size, posY - size, posX + size * 0.5, posY - size )


    posX = posX + 1
    posY = posY + 1
    surface.SetDrawColor( 0, 0, 0, 100 )
    surface.DrawLine( posX - size, posY + size, posX - size * 0.5, posY + size )
    surface.DrawLine( posX + size, posY + size, posX + size * 0.5, posY + size )

    surface.DrawLine( posX - size, posY + size, posX - size, posY + size * 0.5 )
    surface.DrawLine( posX - size, posY - size, posX - size, posY - size * 0.5 )

    surface.DrawLine( posX + size, posY + size, posX + size, posY + size * 0.5 )
    surface.DrawLine( posX + size, posY - size, posX + size, posY - size * 0.5 )

    surface.DrawLine( posX - size, posY - size, posX - size * 0.5, posY - size )
    surface.DrawLine( posX + size, posY - size, posX + size * 0.5, posY - size )
end

