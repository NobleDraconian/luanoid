local Workspace = game:GetService("Workspace")

local Animation = require(script.Parent.Parent.Animation)
local castCylinder = require(script.Parent.Parent.castCylinder)
local CollisionMask = require(script.Parent.Parent.CollisionMask)
local getModelMass = require(script.Parent.Parent.getModelMass)
local stepSpring = require(script.Parent.Parent.stepSpring)

local FRAMERATE = 1 / 240
local STIFFNESS = 170
local DAMPING = 26
local PRECISION = 0.001
local TARGET_SPEED = 24
local HIP_HEIGHT = 3.1
local POP_TIME = 0.05 -- target time to reach target height

local COLLISION_MASK = {
	LeftFoot = false,
	LeftLowerLeg = false,
	LeftUpperLeg = false,
	LeftHand = false,
	LeftLowerArm = false,
	LeftUpperArm = false,
	RightFoot = false,
	RightLowerLeg = false,
	RightUpperLeg = false,
	RightHand = false,
	RightLowerArm = false,
	RightUpperArm = false,
}

local THETA = math.pi * 2

local function createForces(character)
	local orient0 = Instance.new("Attachment")
	orient0.Name = "Align0"
	orient0.Parent = character.instance.PrimaryPart

	local orient1 = Instance.new("Attachment")
	orient1.Name = "Align1"
	orient1.Parent = Workspace.Terrain

	local orientation = Instance.new("AlignOrientation")
	orientation.RigidityEnabled = true
	orientation.Attachment0 = orient0
	orientation.Attachment1 = orient1
	orientation.Parent = character.instance.PrimaryPart

	local velocity0 = Instance.new("Attachment")
	velocity0.Name = "Velocity0"
	velocity0.Parent = character.instance.PrimaryPart

	local vectorForce = Instance.new("VectorForce")
	vectorForce.ApplyAtCenterOfMass = true
	vectorForce.Force = Vector3.new(0, 0, 0)
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.Attachment0 = velocity0
	vectorForce.Parent = character.instance.PrimaryPart

	return {
		orient0 = orient0,
		orient1 = orient1,
		orientation = orientation,

		velocity0 = velocity0,
		vectorForce = vectorForce,
	}
end

-- loop between 0 - 2*pi
local function angleAbs(angle)
	while angle < 0 do
		angle = angle + THETA
	end
	while angle > THETA do
		angle = angle - THETA
	end
	return angle
end

local function angleShortest(a0, a1)
	local d1 = angleAbs(a1 - a0)
	local d2 = -angleAbs(a0 - a1)
	return math.abs(d1) > math.abs(d2) and d2 or d1
end

local function lerpAngle(a0, a1, alpha)
	return a0 + angleShortest(a0, a1)*alpha
end

local function makeCFrame(up, look)
	local upu = up.Unit
	local looku = (Vector3.new() - look).Unit
	local rightu = upu:Cross(looku).Unit
	-- orthonormalize, keeping up vector
	looku = -upu:Cross(rightu).Unit
	return CFrame.new(0, 0, 0, rightu.x, upu.x, looku.x, rightu.y, upu.y, looku.y, rightu.z, upu.z, looku.z)
end

local Walking = {}
Walking.__index = Walking

function Walking.new(simulation)
	local steepestInclineAngle = 60*(math.pi/180)
	local maxInclineTan = math.tan(steepestInclineAngle)
	local maxInclineStartTan = math.tan(math.max(0, steepestInclineAngle - 2.5*(math.pi/180)))

	local state = {
		simulation = simulation,
		character = simulation.character,
		animation = simulation.animation,

		accumulatedTime = 0,
		currentAccelerationX = 0,
		currentAccelerationY = 0,
		maxInclineTan = maxInclineTan,
		maxInclineStartTan = maxInclineStartTan,
		debugAdorns = {},
		forces = nil, -- Defined in enterState
	}

	setmetatable(state, Walking)

	return state
end

function Walking:enterState(oldState, options)
	self.forces = createForces(self.character)

	CollisionMask.apply(self.character.instance, COLLISION_MASK)

	if options and options.biasImpulse then
		self.biasImpulse = options.biasImpulse
	end

	self.animation:setState(Animation.State.Idle)
end

function Walking:leaveState()
	for _, object in pairs(self.forces) do
		object:Destroy()
	end

	CollisionMask.revert(self.character.instance, COLLISION_MASK)

	for _, adorn in pairs(self.debugAdorns) do
		adorn:destroy()
	end

	self.accumulatedTime = 0
	self.currentAccelerationX = 0
	self.currentAccelerationY = 0

	self.debugAdorns = {}

	self.animation.animations.walk:AdjustSpeed(1)
	self.animation:setState(Animation.State.None)
end

function Walking:step(dt, input)
	local characterMass = getModelMass(self.character.instance)

	local targetX = 0
	local targetY = 0

	if input.movementX ~= 0 or input.movementY ~= 0 then
		local cameraLook = Workspace.CurrentCamera.CFrame.lookVector
		local cameraAngle = math.atan2(cameraLook.x, cameraLook.z)

		local magnitude = math.sqrt(input.movementX^2 + input.movementY^2)
		local unitX = input.movementX / magnitude
		local unitY = input.movementY / magnitude

		local relativeX = unitX * math.cos(cameraAngle) + unitY * math.sin(cameraAngle)
		local relativeY = -unitX * math.sin(cameraAngle) + unitY * math.cos(cameraAngle)

		targetX = TARGET_SPEED * relativeX
		targetY = TARGET_SPEED * relativeY
	end

	self.accumulatedTime = self.accumulatedTime + dt

	local currentVelocity = self.character.instance.PrimaryPart.Velocity;
	local currentX = currentVelocity.X
	local currentY = currentVelocity.Z

	while self.accumulatedTime >= FRAMERATE do
		self.accumulatedTime = self.accumulatedTime - FRAMERATE

		currentX, self.currentAccelerationX = stepSpring(
			FRAMERATE,
			currentX,
			self.currentAccelerationX,
			targetX,
			STIFFNESS,
			DAMPING,
			PRECISION
		)

		currentY, self.currentAccelerationY = stepSpring(
			FRAMERATE,
			currentY,
			self.currentAccelerationY,
			targetY,
			STIFFNESS,
			DAMPING,
			PRECISION
		)
	end

	local speed = Vector3.new(currentX, 0, currentY).Magnitude
	local radius = math.min(2, math.max(1.5, speed/TARGET_SPEED*2))
	local biasVelicityFactor = 0.075 -- fudge constant
	local biasRadius = math.max(speed/TARGET_SPEED*2, 1)
	local biasCenter = Vector3.new(currentX*biasVelicityFactor, 0, currentY*biasVelicityFactor)

	if self.biasImpulse then
		biasCenter = biasCenter + self.biasImpulse
		self.biasImpulse = self.biasImpulse * 0.9
	end

	local onGround, groundHeight, steepness, _, normal = castCylinder({
		origin = self.character.castPoint.WorldPosition,
		direction = Vector3.new(0, -HIP_HEIGHT*2, 0),
		steepTan = self.maxInclineTan,
		steepStartTan = self.maxInclineStartTan,
		radius = radius,
		biasCenter = biasCenter,
		biasRadius = biasRadius,
		adorns = self.debugAdorns,
		ignoreInstance = self.character.instance,
		hipHeight = HIP_HEIGHT,
	})

	local targetHeight = groundHeight + HIP_HEIGHT
	local currentHeight = self.character.castPoint.WorldPosition.Y

	local bottomColor = onGround and Color3.new(0, 1, 0) or Color3.new(1, 0, 0)
	self.character.instance.PrimaryPart.Color = bottomColor

	if onGround then
		local aUp

		local jumpHeight = 10
		local jumpInitialVelocity = math.sqrt(Workspace.Gravity*2*jumpHeight)
		if input.jump and currentVelocity.Y < jumpInitialVelocity then
			aUp = 0
			self.character.instance.PrimaryPart.Velocity = Vector3.new(currentX, jumpInitialVelocity, currentY)
		else
			local t = POP_TIME
			-- counter gravity and then solve constant acceleration eq
			-- (x1 = x0 + v*t + 0.5*a*t*t) for a to aproach target height over time
			aUp = Workspace.Gravity + 2*((targetHeight-currentHeight) - currentVelocity.Y*t)/(t*t)
		end
		-- downward acceleration cuttoff (limited ability to push yourself down)
		aUp = math.max(-1, aUp)

		local aX = self.currentAccelerationX
		local aY = self.currentAccelerationY
		if normal and steepness > 0 then
			-- deflect control acceleration off slope normal, discarding the parallell component
			local aControl = Vector3.new(aX, 0, aY)
			local dot = math.min(0, normal:Dot(aControl)) -- clamp below 0, don't subtract forces away from normal
			local aInto = normal*dot
			local aPerp = aControl - aInto
			local aNew = aPerp
			aNew = aControl:Lerp(aNew, steepness)
			aX, aY = aNew.X, aNew.Z

			-- mass on a frictionless incline: net acceleration = g * sin(incline angle)
			local aGravity = Vector3.new(0, -Workspace.Gravity, 0)
			dot = math.min(0, normal:Dot(aGravity))
			aInto = normal*dot
			aPerp = aGravity - aInto
			aNew = aPerp
			aX, aY = aX + aNew.X*steepness, aY + aNew.Z*steepness
			aUp = aUp + aNew.Y*steepness

			aUp = math.max(0, aUp)
		end

		self.forces.vectorForce.Force = Vector3.new(aX*characterMass, aUp*characterMass, aY*characterMass)
	else
		self.forces.vectorForce.Force = Vector3.new(0, 0, 0)
	end

	local velocity = Vector3.new(currentX, 0, currentY)
	local lookVector = self.character.instance.PrimaryPart.CFrame.lookVector

	if onGround then
		if velocity.Magnitude <= 5 then
			self.animation:setState(Animation.State.Idle)
		else
			self.animation:setState(Animation.State.Walking)
			self.animation.animations.walk:AdjustSpeed(velocity.Magnitude / 16)
		end
	else
		self.animation:setState(Animation.State.Falling)
	end

	if velocity.Magnitude > 0.1 and lookVector.y < 0.9 then
		-- Fix "tumbling" where AlignOrientation might pick the "wrong" axis when we cross through 0, lerp angles...
		local currentAngle = math.atan2(lookVector.z, lookVector.x)
		local targetAngle = math.atan2(currentY, currentX)
		-- If we crossed through 0 (shortest arc angle is close to pi) then lerp the angle...
		if math.abs(angleShortest(currentAngle, targetAngle)) > math.pi*0.95 then
			targetAngle = lerpAngle(currentAngle, targetAngle, 0.95)
		end

		local up = Vector3.new(0, 1, 0)
		local look = Vector3.new(math.cos(targetAngle), 0, math.sin(targetAngle))
		self.forces.orient1.CFrame = makeCFrame(up, look)
	end

	-- Climbing transition check
	local climbOptions = self.simulation.states.Climbing:check()
	if climbOptions then
		return self.simulation:setState(self.simulation.states.Climbing, climbOptions)
	end

	if input.ragdoll then
		return self.simulation:setState(self.simulation.states.Ragdoll)
	end
end

return Walking