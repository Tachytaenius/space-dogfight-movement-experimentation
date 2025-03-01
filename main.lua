-- TODO: Angular drag with consistent units. Implement a more sensible idea of angular force, too?
-- TODO: Automatic forward thrust with throttle

local mathsies = require("lib.mathsies")
local vec3 = mathsies.vec3
local quat = mathsies.quat
local mat4 = mathsies.mat4

local controls = require("controls")
local consts = require("consts")

local normaliseOrZero = require("util.normalise-or-zero")
local getAccelerationMultiplier1 = require("util.get-acceleration-multiplier-1")
local getAccelerationMultiplier2 = require("util.get-acceleration-multiplier-2")
local axisAngleVectorBetweenVectors = require("util.axis-angle-between-vectors")
local moveVectorToTarget = require("util.move-vector-to-target")
local setVectorLength = require("util.set-vector-length")
local limitVectorLength = require("util.limit-vector-length")
local handleVelocityVector = require("util.handle-velocity-vector")
local lerp = require("util.lerp")
local sign = require("util.sign")

local spheres, sphereMesh
local ships, shipMesh
local player
local canvas, shader
local loadObj = require("util.load-obj")

local mouseDx, mouseDy

local function getTargetRotationEffectMultiplier(ship)
	local speedDifference = #ship.velocity - ship.rotationEffectMultiplierOptimumSpeed
	local range, lowest
	if speedDifference > 0 then
		range = ship.rotationEffectMultiplierFalloffRangeAbove
		lowest = ship.lowestRotationEffectMultiplierAbove
	else
		range = ship.rotationEffectMultiplierFalloffRangeBelow
		lowest = ship.lowestRotationEffectMultiplierBelow
	end
	local speedDistance = math.abs(speedDifference)
	if range == 0 then
		-- Avoid dividing by zero
		return speedDistance <= range and 1 or lowest
	end
	return math.max(lowest, math.min(1,
		(lowest - 1) *  speedDistance / range + 1
	))
end

function love.load()
	sphereMesh = loadObj("meshes/icosahedron.obj").mesh
	spheres = {}
	for i = 1, 200 do
		spheres[i] = {
			position = (vec3(
				love.math.random(),
				love.math.random(),
				love.math.random()
			) * 2 - 1) * 1000,
			radius = 10,
			velocity = vec3()
		}
	end

	player = {
		position = vec3(),
		velocity = vec3(),
		orientation = quat(),
		angularVelocity = vec3(),
		radius = 2,

		forwardsThrustForce = 125e4,
		backwardsThrustForce = 75e4,
		sidewaysThrustForce = 75e4,
		-- Max speeds can be unreachable due to drag, but still affect the curve of acceleration
		forwardsMaxSpeed = 400,
		backwardsMaxSpeed = 300,
		sidewaysMaxSpeed = 150,
		engineAccelerationCurveShaper = 1.5,

		angularForce = 2e4,
		maxAngularSpeed = 1,
		angularMovementTypeLerpFactor = 0.5,
		angularPassiveDecelerationForceAboveMaxAngularSpeed = 2.5e4,
		angularPerpendicularDecelerationForceAboveMaxAngularSpeed = 10e4,

		rotationEffectMultiplierOptimumSpeed = 125,
		lowestRotationEffectMultiplierBelow = 0.25,
		rotationEffectMultiplierFalloffRangeBelow = 75,
		lowestRotationEffectMultiplierAbove = 0.375,
		rotationEffectMultiplierFalloffRangeAbove = 50,
		rotationEffectMultiplierBaseChangeRate = 0.01, -- nil for instant
		rotationEffectMultiplierDistanceToRateMultiplier = 3,
		currentRotationEffectMultiplier = nil, -- Initialised by initial speed

		dragCoefficient = 0.3,
		dragArea = 100, -- Would depend on direction
		angularDrag = 0.25,
		sidewaysDecelerationForceMax = 25e4,
		brakeForceMax = 100e4,

		mass = 1e4,

		accelerationDampingMultiplierMode = "1" -- Won't be using 2 but it was interesing to try
	}
	ships = {}
	ships[#ships + 1] = player

	canvas = love.graphics.newCanvas(love.graphics.getDimensions())
	shader = love.graphics.newShader("shaders/mesh.glsl")
end

function love.mousemoved(_, _, dx, dy)
	mouseDx, mouseDy = dx, dy
end

function love.mousepressed()
	love.mouse.setRelativeMode(not love.mouse.getRelativeMode())
end

function love.update(dt)
	if not (mouseDx and mouseDy) or love.mouse.getRelativeMode() == false then
		mouseDx = 0
		mouseDy = 0
	end

	-- Handle temporary frame variables and such
	for _, ship in ipairs(ships) do
		ship.currentRotationEffectMultiplier = ship.currentRotationEffectMultiplier or getTargetRotationEffectMultiplier(ship)
	end

	if player then
		-- Get inputs
		local keyboardTranslation = vec3()
		if love.keyboard.isDown(controls.moveLeft) then keyboardTranslation = keyboardTranslation + consts.rightVector end
		if love.keyboard.isDown(controls.moveRight) then keyboardTranslation = keyboardTranslation - consts.rightVector end
		if love.keyboard.isDown(controls.moveUp) then keyboardTranslation = keyboardTranslation + consts.upVector end
		if love.keyboard.isDown(controls.moveDown) then keyboardTranslation = keyboardTranslation - consts.upVector end
		if love.keyboard.isDown(controls.moveForwards) then keyboardTranslation = keyboardTranslation + consts.forwardVector end
		if love.keyboard.isDown(controls.moveBackwards) then keyboardTranslation = keyboardTranslation - consts.forwardVector end
		player.engineVectorShipSpace = normaliseOrZero(keyboardTranslation) -- Scaled by direction-dependant engine power later. This is a dimensionless multiplier

		local mouseMovementForMaxRotationInputCursorLength = 40 -- Move this amount to go move rotationInputCursor's magnitude from 0 to 1
		player.rotationInputCursor = limitVectorLength(
			(player.rotationInputCursor or vec3()) + -- Will never have anything on the z axis
				consts.upVector * mouseDx / mouseMovementForMaxRotationInputCursorLength +
				consts.rightVector * mouseDy / mouseMovementForMaxRotationInputCursorLength,
			1
		)
		if love.keyboard.isDown(controls.recentreRotationCursor) then
			player.rotationInputCursor = vec3()
		end

		local keyboardRotation = vec3()
		if love.keyboard.isDown(controls.yawLeft) then keyboardRotation = keyboardRotation - consts.upVector end
		if love.keyboard.isDown(controls.yawRight) then keyboardRotation = keyboardRotation + consts.upVector end
		if love.keyboard.isDown(controls.pitchUp) then keyboardRotation = keyboardRotation - consts.rightVector end
		if love.keyboard.isDown(controls.pitchDown) then keyboardRotation = keyboardRotation + consts.rightVector end
		if love.keyboard.isDown(controls.rollClockwise) then keyboardRotation = keyboardRotation - consts.forwardVector end
		if love.keyboard.isDown(controls.rollAnticlockwise) then keyboardRotation = keyboardRotation + consts.forwardVector end
		local targetAngularVelocityMultiplierVector = limitVectorLength(normaliseOrZero(keyboardRotation) + player.rotationInputCursor, 1)
		local effectiveMaxAngularSpeed = player.currentRotationEffectMultiplier * player.maxAngularSpeed
		local inputMaxSpeed = math.max(effectiveMaxAngularSpeed, #player.angularVelocity) -- Defines what target speed a targetAngularVelocityMultiplierVector magnitude of 1 means. Can be an arbitrary number
		player.targetAngularVelocity = targetAngularVelocityMultiplierVector * inputMaxSpeed

		player.brakeMultiplier = love.keyboard.isDown(controls.brake) and 1 or 0
		player.sidewaysBrakeMultiplier = love.keyboard.isDown(controls.sidewaysBrake) and 1 or 0
	end

	-- Make inputs change things
	for _, ship in ipairs(ships) do
		-- Drag and braking
		local speed = #ship.velocity
		local slowdownForce = 0
		slowdownForce = slowdownForce + ship.brakeMultiplier * ship.brakeForceMax -- Braking
		slowdownForce = slowdownForce + 1/2 * consts.airDensity * speed ^ 2 * ship.dragCoefficient * ship.dragArea -- Drag
		local slowdown = slowdownForce / ship.mass
		ship.velocity = setVectorLength(ship.velocity, math.max(0, #ship.velocity - slowdown * dt))

		-- Sideways deceleration
		-- Split velocity into parallel and perpendicular components with respect to facing direction
		local facingDirection = vec3.rotate(consts.forwardVector, ship.orientation)
		local dot = vec3.dot( -- Dot of A with normalised B is A in direction of B
			ship.velocity,
			facingDirection
		)
		local velocityParallel = dot * facingDirection
		local velocityPerpendicular = ship.velocity - velocityParallel
		-- Get force as acceleration
		local sidewaysDecelerationForce = ship.sidewaysBrakeMultiplier * ship.sidewaysDecelerationForceMax
		local sidewaysDeceleration = sidewaysDecelerationForce / ship.mass
		-- Reduce perpendicular by acceleration
		local velocityPerpendicularReduced = setVectorLength(
			velocityPerpendicular,
			math.max(0, #velocityPerpendicular - sidewaysDeceleration * dt)
		)
		-- Recombine
		ship.velocity = velocityParallel + velocityPerpendicularReduced

		-- Engine acceleration
		-- Get pre-damped acceleration in world space
		local accelerationVector
		local preDampedEngineAccelerationShipSpace = ship.engineVectorShipSpace * vec3(
			ship.sidewaysThrustForce,
			ship.sidewaysThrustForce,
			ship.engineVectorShipSpace.z > 0 and ship.forwardsThrustForce or ship.backwardsThrustForce
		) / ship.mass
		local preDampedEngineAccelerationWorldSpace = vec3.rotate(preDampedEngineAccelerationShipSpace, ship.orientation)
		-- Get max speed for this direction
		local maxSpeedThisDirection = #vec3.rotate(
			normaliseOrZero(ship.engineVectorShipSpace) * vec3(
				ship.sidewaysMaxSpeed,
				ship.sidewaysMaxSpeed,
				ship.engineVectorShipSpace.z > 0 and ship.forwardsMaxSpeed or ship.backwardsMaxSpeed
			),
			ship.orientation
		)
		-- Get damped acceleration vector
		if #ship.velocity > 0 then
			-- Split pre-damped acceleration into parallel and perpendicular components with respect to velocity direction
			local velocityDirection = vec3.normalise(ship.velocity)
			local dot = vec3.dot(
				preDampedEngineAccelerationWorldSpace,
				velocityDirection
			)
			local preDampedAccelerationParallel = dot * velocityDirection
			local accelerationPerpendicular = preDampedEngineAccelerationWorldSpace - preDampedAccelerationParallel

			-- Get damping multiplier
			local dampingMultiplier
			if ship.accelerationDampingMultiplierMode == "1" then
				dampingMultiplier = getAccelerationMultiplier1(#ship.velocity, dot, maxSpeedThisDirection, ship.engineAccelerationCurveShaper)
			elseif ship.accelerationDampingMultiplierMode == "2" then
				dampingMultiplier = getAccelerationMultiplier2(ship.velocity, preDampedEngineAccelerationWorldSpace, maxSpeedThisDirection, ship.engineAccelerationCurveShaper)
			end

			-- Multiply parallel component and recombine
			local dampedAccelerationParallel = preDampedAccelerationParallel * dampingMultiplier
			accelerationVector = accelerationPerpendicular + dampedAccelerationParallel
		else
			accelerationVector = preDampedEngineAccelerationWorldSpace
		end
		-- If acceleration would increase speed while being over max speed, cap it to previous speed or max speed, whichever is higher. Preserves direction
		local attemptedDelta = accelerationVector * dt
		local attemptedNewVelocity = ship.velocity + attemptedDelta
		local finalDelta, finalNewVelocity
		if #attemptedNewVelocity > maxSpeedThisDirection and #attemptedNewVelocity > #ship.velocity then
			finalNewVelocity = setVectorLength(
				attemptedNewVelocity,
				math.max(maxSpeedThisDirection, #ship.velocity) * consts.speedRegulationMultiplier -- Speed regulation multiplier is there to stop precision from letting you go faster and faster. It's a quantity a tiny bit below 1
			)
			finalDelta = finalNewVelocity - ship.velocity
			-- #finalDelta may be larger than #attemptedDelta
			-- assert(#finalNewVelocity <= #attemptedNewVelocity, "Attempted to prevent speed increase but speed increased anyway") -- Not confident in the precision when small numbers are involved
		else
			finalDelta = attemptedDelta
			finalNewVelocity = attemptedNewVelocity
		end
		local dampedAcceleration = finalDelta / dt -- If you want to draw an acceleration vector, use this
		ship.velocity = finalNewVelocity

		-- Rotaion
		-- Use current rotation effect multiplier
		local effectiveMaxAngularSpeed = ship.maxAngularSpeed * ship.currentRotationEffectMultiplier
		local effectiveAngularForce = ship.angularForce * ship.currentRotationEffectMultiplier
		-- Move angular velocity vector using effect multiplier on affected ship stats
		ship.angularVelocity = handleVelocityVector(
			ship.angularVelocity,
			ship.targetAngularVelocity,
			effectiveAngularForce / ship.mass,
			dt,
			ship.angularMovementTypeLerpFactor,
			effectiveMaxAngularSpeed,
			ship.angularPassiveDecelerationForceAboveMaxAngularSpeed / ship.mass,
			ship.angularPerpendicularDecelerationForceAboveMaxAngularSpeed / ship.mass
		)
		-- Move current effect multiplier to target.
		-- This is done after current effect multiplier is used because current is also used to make targetAngularVelocity before in the same update,
		-- and they should use the same value. Could also move current rotation effect multiplier change to before that.
		local targetRotationEffectMultiplier = getTargetRotationEffectMultiplier(ship)
		if ship.rotationEffectMultiplierBaseChangeRate then
			ship.currentRotationEffectMultiplier = ship.currentRotationEffectMultiplier or targetRotationEffectMultiplier -- Sensible default
			local delta = targetRotationEffectMultiplier - ship.currentRotationEffectMultiplier
			local finalRate = ship.rotationEffectMultiplierBaseChangeRate + math.abs(delta) * ship.rotationEffectMultiplierDistanceToRateMultiplier
			ship.currentRotationEffectMultiplier =
				targetRotationEffectMultiplier
				- sign(delta)
				* math.max(
					0,
					math.abs(delta) - finalRate * dt
				)
		else
			ship.currentRotationEffectMultiplier = targetRotationEffectMultiplier
		end
	end

	for _, ship in ipairs(ships) do
		ship.position = ship.position + ship.velocity * dt
		ship.orientation = quat.normalise(ship.orientation * quat.fromAxisAngle(ship.angularVelocity * dt))
	end

	mouseDx, mouseDy = nil, nil
end

function love.draw()
	love.graphics.setDepthMode("lequal", true)
	love.graphics.setCanvas({canvas, depth = true})
	love.graphics.clear()

	love.graphics.setShader(shader)

	local cameraToClipMatrix = mat4.perspectiveLeftHanded(canvas:getWidth() / canvas:getHeight(), math.rad(70), 10000, 0.1)
	local worldToCameraMatrix = mat4.camera(player.position, player.orientation)
	local worldToClipMatrix = cameraToClipMatrix * worldToCameraMatrix
	for _, sphere in ipairs(spheres) do
		local modelToWorldMatrix = mat4.transform(sphere.position, quat(), sphere.radius)
		local modelToClipMatrix = worldToClipMatrix * modelToWorldMatrix
		shader:send("modelToClip", {mat4.components(modelToClipMatrix)})
		love.graphics.draw(sphereMesh)
	end

	love.graphics.setShader()

	love.graphics.setCanvas()
	love.graphics.draw(canvas, 0, canvas:getHeight(), 0, 1, -1)

	local playerFacingVector = vec3.rotate(consts.forwardVector, player.orientation)
	love.graphics.print(
		"FPS: " .. love.timer.getFPS() .. "\n" ..
		"Speed: " .. math.floor(#player.velocity + 0.5) .. "\n" ..
		"Forward velocity: " .. math.floor(vec3.dot(player.velocity, playerFacingVector) + 0.5) .. "\n" ..
		"Velocity to facing angle difference: " .. (
			#player.velocity > 0 and
				math.floor(
					math.acos(
						math.max(-1, math.min(1,
							vec3.dot(
								vec3.normalise(player.velocity),
								playerFacingVector
							)
						))
					)
					/ (consts.tau / 2) * 100 + 0.5
				) .. "%"
			or
				"N/A"
		) .. "\n" ..
		"Angular speed: " .. math.floor(#player.angularVelocity * 1000 + 0.5) / 1000 .. "\n" ..
		"Rotation effect multiplier: " .. math.floor(player.currentRotationEffectMultiplier * 1000 + 0.5) / 1000
	)
end
