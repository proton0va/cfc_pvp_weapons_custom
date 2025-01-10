AddCSLuaFile()

ENT.Type = "anim"

function ENT:SetupDataTables()
    self:NetworkVar( "Bool", 0, "Disabled" )
    self:NetworkVar( "Bool", 1, "CleanMissile" )
    self:NetworkVar( "Bool", 2, "DirtyMissile" )
    self:NetworkVar( "Bool", 3, "HasTarget" ) -- glide lockon handler
    self:NetworkVar( "Entity", 0, "Attacker" )
    self:NetworkVar( "Entity", 1, "Inflictor" )
    self:NetworkVar( "Entity", 2, "LockOn" )
end

if SERVER then

    local stingerDmgMulCvar = CreateConVar( "cfc_stinger_damagemul", 1, FCVAR_ARCHIVE )
    local stingerMobilityMul = CreateConVar( "cfc_stinger_mobilitymul", 1, FCVAR_ARCHIVE )
    local stingerDirectHitPlayerMul = CreateConVar( "cfc_stinger_directhitplayersmul", 1, FCVAR_ARCHIVE )

    local BLINDFIRE_MAXSPEED_TIME = 1.5
    local MAX_BLINDFIRE_SPEED = 3000

    local GetClosestFlare
    if Glide then
        GetClosestFlare = Glide.GetClosestFlare
    end

    sound.Add( {
        name = "cfc_stinger_impactflesh",
        channel = CHAN_STATIC,
        volume = 1.0,
        level = 130,
        pitch = { 90, 100 },
        sound = {
            "physics/flesh/flesh_squishy_impact_hard1.wav",
            "physics/flesh/flesh_squishy_impact_hard2.wav",
            "physics/flesh/flesh_squishy_impact_hard3.wav",
            "physics/flesh/flesh_squishy_impact_hard4.wav"
        }
    } )

    function ENT:SpawnFunction( _, tr, className )
        if not tr.Hit then return end

        local ent = ents.Create( className )
        ent:SetPos( tr.HitPos + tr.HitNormal * 20 )
        ent:Spawn()
        ent:Activate()

        return ent
    end

    function ENT:BlindFire()
        if self:GetDisabled() then return end
        if self:DoHitTrace() then return end

        local pObj = self:GetPhysicsObject()

        if IsValid( pObj ) then
            -- ramp up to full speed over a bit less than 1 second
            local timeAlive = math.abs( self:GetCreationTime() - CurTime() )
            local tillFullSpeed = timeAlive / BLINDFIRE_MAXSPEED_TIME
            local speed = math.Clamp( tillFullSpeed * MAX_BLINDFIRE_SPEED, 0, MAX_BLINDFIRE_SPEED )
            local vel = ( speed * stingerMobilityMul:GetFloat() )
            pObj:SetVelocityInstantaneous( self:GetForward() * vel )

            local angVel = pObj:GetAngleVelocity() * 0.995 -- bias towards going straight, spiral out of turns

            local instability
            if tillFullSpeed >= 1 then -- drift a LOT once we get to max speed
                instability = 0.15
            else
                instability = 0.08
            end
            angVel = angVel + VectorRand() * instability -- but dont go perfectly straight

            pObj:SetAngleVelocity( angVel )
        end
    end

    function ENT:FollowTarget( followEnt )
        -- increase turnrate the longer missile is alive, bear down on far targets.
        -- goal is to punish pilots/drivers who camp far away from players.
        local timeAlive = math.abs( self:GetCreationTime() - CurTime() )
        local turnrateAdd = math.Clamp( timeAlive * 75, 0, 400 ) * stingerMobilityMul:GetFloat()
        local speedAdd = math.Clamp( timeAlive * 650, 0, 10000 ) * stingerMobilityMul:GetFloat()

        local speed = self:GetDirtyMissile() and 1000 or 1500
        speed = speed + speedAdd

        local turnrate = 20
        turnrate = turnrate + turnrateAdd

        local parent = followEnt:GetParent()
        if IsValid( parent ) and parent:IsVehicle() then
            followEnt = parent
        end

        local myPos = self:GetPos()
        local targetPos
        local followsPhysObj = followEnt:GetPhysicsObject()

        if GetClosestFlare then -- glide flares do something
            local flare = GetClosestFlare( myPos, self:GetForward(), 700 ) -- glide homing missile is 1500 dist
            if IsValid( flare ) then
                targetPos = flare:WorldSpaceCenter()
            end
        end

        if not targetPos then
            if isfunction( followEnt.GetMissileOffset ) then
                local value = followEnt:GetMissileOffset()
                if isvector( value ) then
                    targetPos = followEnt:LocalToWorld( value )
                end
            else
                targetPos = followEnt:WorldSpaceCenter()
            end
        end

        local pos = targetPos + followEnt:GetVelocity() * 0.15
        local pObj = self:GetPhysicsObject()

        if IsValid( pObj ) and not self:GetDisabled() then
            local subtractionProduct = pos - myPos
            local distToTargSqr = subtractionProduct:LengthSqr()
            local targetdir = subtractionProduct:GetNormalized()

            local AF = self:WorldToLocalAngles( targetdir:Angle() )
            local badAngles = AF.p > 95 or AF.y > 95

            -- if you want to make a plane/vehicle not get targeted by the launcher then see CFC_Stinger_BlockLockon hook, in the launcher

            if distToTargSqr < 500^2 and self:DoHitTrace( myPos ) then -- close to target, start doing traces in front of us
                return
            -- target is cheating! they're no collided!
            elseif distToTargSqr < 75^2 then
                self:HitEntity( followEnt )
                return
            -- target escaped!
            elseif badAngles then
                self:SetLockOn( nil )
                return
            end

            AF.p = math.Clamp( AF.p * 400, -turnrate, turnrate )
            AF.y = math.Clamp( AF.y * 400, -turnrate, turnrate )
            AF.r = math.Clamp( AF.r * 400, -turnrate, turnrate )

            local AVel = pObj:GetAngleVelocity()
            if not IsValid( pObj ) then return end
            pObj:AddAngleVelocity( Vector( AF.r, AF.p, AF.y ) - AVel )

            pObj:SetVelocityInstantaneous( self:GetForward() * speed )
        end
    end

    function ENT:Initialize()
        self:SetModel( "models/weapons/w_missile_launch.mdl" )
        self:PhysicsInit( SOLID_VPHYSICS )
        self:SetMoveType( MOVETYPE_VPHYSICS )
        self:SetSolid( SOLID_VPHYSICS )
        self:SetRenderMode( RENDERMODE_TRANSALPHA )
        self:PhysWake()
        local pObj = self:GetPhysicsObject()

        if IsValid( pObj ) then
            pObj:EnableGravity( false )
            pObj:SetMass( 1 )
        end

        self.SpawnTime = CurTime()
    end

    function ENT:Think()
        local curtime = CurTime()
        self:NextThink( curtime )

        local target = self:GetLockOn()
        if IsValid( target ) then
            if not self.DoneMissileDanger then
                self:HandleMissileDanger( target )
            end

            self:FollowTarget( target )
        else
            self:BlindFire()
        end

        if ( self.SpawnTime + 12 ) < curtime then
            self:Detonate()
        end

        return true
    end

    function ENT:PhysicsCollide( data )
        if self:GetDisabled() then
            self:Detonate()
        else
            local hitEnt = data.HitEntity

            self:HitEntity( hitEnt )
        end
    end

    local missileHitboxMax = Vector( 10, 10, 10 )
    local missileHitboxMins = -missileHitboxMax

    function ENT:DoHitTrace( myPos )
        local startPos = myPos or self:GetPos()
        local offset = self:GetForward() * 20
        local inflic = self:GetInflictor()

        local trResult = util.TraceHull( {
            start = startPos,
            endpos = startPos + offset,
            filter = { self, self:GetOwner(), inflic },
            maxs = missileHitboxMax,
            mins = missileHitboxMins,
            mask = MASK_SOLID,
        } )

        if trResult.Hit then
            -- dont hit sub-ents of the inflictor
            if IsValid( inflic ) and IsValid( trResult.Entity:GetParent() ) and trResult.Entity:GetParent() == inflic then return end
            self:HitEntity( trResult.Entity )
            return true
        end
    end

    function ENT:GetDirectHitDamage( hitEnt )
        local hookResultDmg, hookResultSound = hook.Run( "LFS.MissileDirectHitDamage", self, hitEnt )
        if hookResultDmg ~= nil and isnumber( hookResultDmg ) then return hookResultDmg, hookResultSound end

        local dmgAmount = 800
        local dmgSound = "Missile.ShotDown"

        if hitEnt.IsSimfphyscar then
            dmgAmount = 1250
        elseif hitEnt:IsNPC() or hitEnt:IsNextBot() then
            dmgAmount = 200
            local obj = hitEnt:GetPhysicsObject()
            if IsValid( obj ) and obj:GetMaterial() and not string.find( obj:GetMaterial(), "metal" ) then
                dmgSound = "cfc_stinger_impactflesh"
            end
        elseif hitEnt:IsPlayer() then
            -- this ends up getting added with the blastdamage, doesn't need to be too strong
            dmgAmount = 75 * stingerDirectHitPlayerMul:GetFloat()
            dmgSound = "cfc_stinger_impactflesh"
        end

        return dmgAmount, dmgSound
    end

    function ENT:HitEntity( hitEnt )
        if IsValid( hitEnt ) then
            local Pos = self:GetPos()
            -- hit simfphys car instead of simfphys wheel
            if hitEnt.GetBaseEnt and IsValid( hitEnt:GetBaseEnt() ) then
                hitEnt = hitEnt:GetBaseEnt()
            end

            local effectdata = EffectData()
                effectdata:SetOrigin( Pos )
                effectdata:SetNormal( -self:GetForward() )
            util.Effect( "manhacksparks", effectdata, true, true )

            local dmgAmount, dmgSound = self:GetDirectHitDamage( hitEnt )
            dmgAmount = dmgAmount * stingerDmgMulCvar:GetFloat()

            local dmginfo = DamageInfo()
                dmginfo:SetDamage( dmgAmount )
                dmginfo:SetAttacker( IsValid( self:GetAttacker() ) and self:GetAttacker() or self )
                dmginfo:SetDamageType( DMG_DIRECT )
                dmginfo:SetInflictor( self )
                dmginfo:SetDamagePosition( Pos )
                dmginfo:SetDamageForce( self:GetForward() * dmgAmount * 500 )
            hitEnt:TakeDamageInfo( dmginfo )

            sound.Play( dmgSound, Pos, 140 )
        end

        self:Detonate()
    end

    function ENT:BreakMissile()
        if not self:GetDisabled() then
            self:SetDisabled( true )

            local pObj = self:GetPhysicsObject()

            if IsValid( pObj ) then
                pObj:EnableGravity( true )
                self:PhysWake()
                self:EmitSound( "Missile.ShotDown" )
            end
        end
    end

    function ENT:Detonate()
        local dmgMul = stingerDmgMulCvar:GetFloat()
        local inflictor = self:GetInflictor()
        local attacker = self:GetAttacker()
        local explodePos = self:WorldSpaceCenter()

        local effectdata = EffectData()
            effectdata:SetOrigin( self:GetPos() )
        util.Effect( "Explosion", effectdata )

        self:EmitSound( "vehicles/airboat/pontoon_impact_hard1.wav", 100, 50, 0.5 )
        self:EmitSound( "Explo.ww2bomb" )

        self:Remove()

        timer.Simple( 0, function()
            local fallbackDamager = Entity( 0 )
            inflictor = IsValid( inflictor ) and inflictor or fallbackDamager
            attacker = IsValid( attacker ) and attacker or fallbackDamager

            util.BlastDamage( inflictor, attacker, explodePos, 200 * dmgMul, 150 * dmgMul )
        end )
    end

    function ENT:OnTakeDamage( dmginfo )
        if not dmginfo:IsDamageType( DMG_AIRBOAT ) then return end
        if self:GetAttacker() == dmginfo:GetAttacker() then return end

        self:BreakMissile()
    end

    function ENT:HandleMissileDanger( target )
        if not Glide then return end

        -- Let Glide vehicles know about this missile
        if target.IsGlideVehicle then
            Glide.SendMissileDanger( target:GetAllPlayers(), self )

        -- Let players in seats know about this missile
        elseif target:IsVehicle() then
            local driver = target:GetDriver()

            if IsValid( driver ) then
                Glide.SendMissileDanger( driver, self )
            end
        end
    end

else -- client
    function ENT:Initialize()
        self.snd = CreateSound( self, "weapons/flaregun/burn.wav" )
        self.snd:SetSoundLevel( 90 )
        self.snd:Play()

        -- make trail effect on client init
        -- very very unreliable on server init
        local effectdata = EffectData()
            effectdata:SetOrigin( self:GetPos() )
            effectdata:SetEntity( self )
        util.Effect( "cfc_stinger_trail", effectdata, true, true )
    end

    function ENT:Draw()
        self:DrawModel()
    end

    function ENT:SoundStop()
        if self.snd then
            self.snd:Stop()
        end
    end

    function ENT:Think()
        if self:GetDisabled() then
            self:SoundStop()
        end

        return true
    end

    function ENT:OnRemove()
        self:SoundStop()
    end
end