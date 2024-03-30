-- TODO: Angular drag with consistent units. Implement a more sensible idea of angular force, too?
-- TODO: Smooth out rotation effect multiplier for better feel
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
local moveVectorToTarget2 = require("util.move-vector-to-target-2")
local lerp = require("util.lerp")

local spheres, sphereMesh
local ships, shipMesh
local player
local canvas, shader
local loadObj = require("util.load-obj")

local mouseDx, mouseDy

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

		forwardsThrustForce = 200e4,
		backwardsThrustForce = 100e4,
		sidewaysThrustForce = 75e4,
		forwardsMaxSpeed = 250,
		backwardsMaxSpeed = 150,
		sidewaysMaxSpeed = 75,
		engineAccelerationCurveShaper = 1.5,

		angularForce = 1.5e4,
		maxAngularSpeed = 0.5,
		angularMovementTypeLerpFactor = 0.5,
		useRotationEffectMultiplier = true, -- Else make all the values below in this group nil
		-- The rotation effect multiplier multiplies your max angular speed and angular force depending on your linear speed's distance to an optimum speed.
		-- It is a plateau at 1 within a region around the optimum speed, decreases towards the lowest value within a larger region around the plateau at 1,
		-- and is always at the lowest value outside the larger region. The two width parameters are the width of the regions from left side to right, not
		-- from one side to the middle.
		--[=[
			|         /-----\
			|        /       \
			|       /         \
			|------/           \------
			|
			+-------------------------
		]=]
		lowestRotationEffectMultiplier = 0.5,
		rotationEffectMultiplierOptimumSpeed = 150,
		rotationEffectMultiplierOptimumSpeedRegionWidth = 5,
		rotationEffectMultiplierFalloffRegionWidth = 150,

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
		player.targetAngularVelocityMultiplierVector = limitVectorLength(normaliseOrZero(keyboardRotation) + player.rotationInputCursor, 1)

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
		-- Get effect multiplier
		local rotationEffectMultiplier
		if ship.useRotationEffectMultiplier then
			assert(
				ship.rotationEffectMultiplierOptimumSpeedRegionWidth <= ship.rotationEffectMultiplierFalloffRegionWidth,
				"Ship rotationEffectMultiplierOptimumSpeedRegionWidth can't be greater than rotationEffectMultiplierFalloffRegionWidth"
			)
			local speedDistance = math.abs(#ship.velocity - ship.rotationEffectMultiplierOptimumSpeed)
			if ship.rotationEffectMultiplierOptimumSpeedRegionWidth == ship.rotationEffectMultiplierFalloffRegionWidth then
				-- Avoid dividing by zero
				rotationEffectMultiplier = speedDistance > ship.rotationEffectMultiplierOptimumSpeedRegionWidth and 1 or ship.lowestRotationEffectMultiplier
			else
				-- This expression was made using Desmos to get the right function and then WolframAlpha to simplify the expression
				rotationEffectMultiplier = math.max(ship.lowestRotationEffectMultiplier, math.min(1,
					(
						ship.rotationEffectMultiplierOptimumSpeedRegionWidth * ship.lowestRotationEffectMultiplier
						- ship.rotationEffectMultiplierFalloffRegionWidth
						-- The 2 here is responsible for makin the region width variables describe the width of the function regions from left side to right side, rather than from side to middle
						- 2 * (ship.lowestRotationEffectMultiplier - 1) * speedDistance
					)
					/ (ship.rotationEffectMultiplierOptimumSpeedRegionWidth - ship.rotationEffectMultiplierFalloffRegionWidth)
				))
			end
		else
			rotationEffectMultiplier = 1
		end
		-- Multiply affected ship stats by effect multiplier
		local effectiveMaxAngularSpeed = ship.maxAngularSpeed * rotationEffectMultiplier
		local effectiveAngularForce = ship.angularForce * rotationEffectMultiplier
		-- Move angular velocity vector using effect multiplier on affected ship stats
		print(rotationEffectMultiplier)
		ship.angularVelocity = moveVectorToTarget2(
			ship.angularVelocity,
			ship.targetAngularVelocityMultiplierVector * effectiveMaxAngularSpeed,
			effectiveAngularForce / ship.mass,
			dt,
			ship.angularMovementTypeLerpFactor
		)
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
		"Angular speed: " .. math.floor(#player.angularVelocity * 1000 + 0.5) / 1000
	)
end
