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

local spheres, sphereMesh
local ships, shipMesh
local player
local canvas, shader
local loadObj = require("util.load-obj")

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

		sidewaysThrustForce = 7500,
		forwardsThrustForce = 20000,
		backwardsThrustForce = 10000,
		maxSpeed = 200,
		engineAccelerationCurveShaper = 1.5,

		angularForce = 50,
		maxAngularSpeed = 1,
		angularMovementTypeLerpFactor = 0.5,

		drag = 0.3,
		angularDrag = 0.25,
		sidewaysDecelerationForceMax = 2500,

		mass = 100,

		accelerationDampingMultiplierMode = "1" -- Won't be using 2 but it was interesing to try
	}
	ships = {}
	ships[#ships + 1] = player

	canvas = love.graphics.newCanvas(love.graphics.getDimensions())
	shader = love.graphics.newShader("shaders/mesh.glsl")
end

function love.update(dt)
	if player then
		-- Get inputs
		local translation = vec3()
		if love.keyboard.isDown(controls.moveLeft) then translation = translation + consts.rightVector end
		if love.keyboard.isDown(controls.moveRight) then translation = translation - consts.rightVector end
		if love.keyboard.isDown(controls.moveUp) then translation = translation + consts.upVector end
		if love.keyboard.isDown(controls.moveDown) then translation = translation - consts.upVector end
		if love.keyboard.isDown(controls.moveForwards) then translation = translation + consts.forwardVector end
		if love.keyboard.isDown(controls.moveBackwards) then translation = translation - consts.forwardVector end
		player.engineVectorShipSpace = normaliseOrZero(translation) -- Scaled by direction-dependant engine power later. This is a dimensionless multiplier

		local rotation = vec3()
		if love.keyboard.isDown(controls.yawLeft) then rotation = rotation - consts.upVector end
		if love.keyboard.isDown(controls.yawRight) then rotation = rotation + consts.upVector end
		if love.keyboard.isDown(controls.pitchUp) then rotation = rotation - consts.rightVector end
		if love.keyboard.isDown(controls.pitchDown) then rotation = rotation + consts.rightVector end
		if love.keyboard.isDown(controls.rollClockwise) then rotation = rotation - consts.forwardVector end
		if love.keyboard.isDown(controls.rollAnticlockwise) then rotation = rotation + consts.forwardVector end
		-- TODO: Mouse
		player.targetAngularVelocityMultiplierVector = normaliseOrZero(rotation)
	end

	-- Make inputs change things
	for _, ship in ipairs(ships) do
		-- TODO: Braking
		-- TODO: Drag and angular drag with consistent units
		-- TODO: Direction-dependant max speed

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
		local sidewaysDecelerationForce = love.keyboard.isDown(controls.sidewaysBrake) and ship.sidewaysDecelerationForceMax or 0
		local sidewaysDeceleration = sidewaysDecelerationForce / ship.mass
		-- Reduce perpendicular by acceleration
		local velocityPerpendicularReduced = setVectorLength(
			velocityPerpendicular,
			math.max(0, #velocityPerpendicular - sidewaysDeceleration * dt)
		)
		-- Recombine
		ship.velocity = velocityParallel + velocityPerpendicularReduced

		local accelerationVector
		local preDampedEngineAccelerationShipSpace = ship.engineVectorShipSpace * vec3(
			ship.sidewaysThrustForce,
			ship.sidewaysThrustForce,
			ship.engineVectorShipSpace.z > 0 and ship.forwardsThrustForce or ship.backwardsThrustForce
		) / ship.mass
		local preDampedEngineAccelerationWorldSpace = vec3.rotate(preDampedEngineAccelerationShipSpace, ship.orientation)
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
				dampingMultiplier = getAccelerationMultiplier1(#ship.velocity, dot, ship.maxSpeed, ship.engineAccelerationCurveShaper)
			elseif ship.accelerationDampingMultiplierMode == "2" then
				dampingMultiplier = getAccelerationMultiplier2(ship.velocity, preDampedEngineAccelerationWorldSpace, ship.maxSpeed, ship.engineAccelerationCurveShaper)
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
		if #attemptedNewVelocity > ship.maxSpeed and #attemptedNewVelocity > ship.velocity then
			finalNewVelocity = setVectorLength(
				attemptedNewVelocity,
				math.max(ship.maxSpeed, #ship.velocity) * consts.speedRegulationMultiplier -- Speed regulation multiplier is there to stop precision from letting you go faster and faster. It's a quantity a tiny bit below 1
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

		ship.angularVelocity = moveVectorToTarget2(
			ship.angularVelocity,
			ship.targetAngularVelocityMultiplierVector * ship.maxAngularSpeed,
			ship.angularForce / ship.mass,
			dt,
			ship.angularMovementTypeLerpFactor
		)
	end

	for _, ship in ipairs(ships) do
		ship.position = ship.position + ship.velocity * dt
		ship.orientation = quat.normalise(ship.orientation * quat.fromAxisAngle(ship.angularVelocity * dt))
	end
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
