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

		sidewaysAcceleration = 75,
		forwardsAcceleration = 200,
		backwardsAcceleration = 100,
		maxSpeed = 200,
		engineAccelerationCurveShaper = 1.5,

		maxAngularAcceleration = 0.6,
		maxAngularSpeed = 1,
		angularMovementTypeLerpFactor = 0.5,

		drag = 0.3,
		angularDrag = 0.25,
		sidewaysVelocityDecelerationMax = 25,

		mass = 100,

		accelerationMultiplierMode = "1" -- Won't be using 2 but it was interesing to try
	}
	ships = {}
	ships[#ships + 1] = player

	canvas = love.graphics.newCanvas(love.graphics.getDimensions())
	shader = love.graphics.newShader("shaders/mesh.glsl")
end

function love.update(dt)
	-- Get inputs
	if player then
		local translation = vec3()
		if love.keyboard.isDown(controls.moveLeft) then translation = translation + consts.rightVector end
		if love.keyboard.isDown(controls.moveRight) then translation = translation - consts.rightVector end
		if love.keyboard.isDown(controls.moveUp) then translation = translation + consts.upVector end
		if love.keyboard.isDown(controls.moveDown) then translation = translation - consts.upVector end
		if love.keyboard.isDown(controls.moveForwards) then translation = translation + consts.forwardVector end
		if love.keyboard.isDown(controls.moveBackwards) then translation = translation - consts.forwardVector end
		player.engineAcceleratorMultiplierVector = normaliseOrZero(translation) -- Scaled depending on direction of motion later

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
		-- TODO: Make everything in terms of force, not acceleration (consider mass of ship) (catch the TODO below about naming as well)
		-- TODO: Braking
		-- TODO: Drag and angular drag with consistent units
		-- TODO: Direction-dependant max speed

		-- Sideways deceleration
		local facingDirection = vec3.rotate(consts.forwardVector, ship.orientation)
		local dot = vec3.dot( -- Dot of A with normalised B is A in direction of B
			ship.velocity,
			facingDirection
		)
		local velocityParallel = dot * facingDirection
		local velocityPerpendicular = ship.velocity - velocityParallel
		local sidewaysDeceleration = love.keyboard.isDown(controls.sidewaysBrake) and ship.sidewaysVelocityDecelerationMax or 0
		local velocityPerpendicularReduced = moveVectorToTarget(velocityPerpendicular, vec3(), sidewaysDeceleration, dt)
		ship.velocity = velocityParallel + velocityPerpendicularReduced

		-- TODO: The naming. Several things are named with acceleration without much clear separation
		local accelerationVector
		local engineAccelerationVector = ship.engineAcceleratorMultiplierVector * vec3(
			ship.sidewaysAcceleration,
			ship.sidewaysAcceleration,
			ship.engineAcceleratorMultiplierVector.z > 0 and ship.forwardsAcceleration or ship.backwardsAcceleration
		)
		local engineAccelerationVectorWorldSpace = vec3.rotate(engineAccelerationVector, ship.orientation)
		if #ship.velocity > 0 then
			-- Split engine acceleration into parallel and perpendicular components with respect to velocity
			local velocityDirection = vec3.normalise(ship.velocity)
			local dot = vec3.dot(
				engineAccelerationVectorWorldSpace,
				velocityDirection
			)
			local accelerationParallel = dot * velocityDirection
			local accelerationPerpendicular = engineAccelerationVectorWorldSpace - accelerationParallel

			-- Get multiplier
			local multiplier
			if ship.accelerationMultiplierMode == "1" then
				multiplier = getAccelerationMultiplier1(#ship.velocity, dot, ship.maxSpeed, ship.engineAccelerationCurveShaper)
			elseif ship.accelerationMultiplierMode == "2" then
				multiplier = getAccelerationMultiplier2(ship.velocity, engineAccelerationVectorWorldSpace, ship.maxSpeed, ship.engineAccelerationCurveShaper)
			end

			-- Multiply perpendicular component and recombine
			local accelerationParallelMultiplied = accelerationParallel * multiplier
			accelerationVector = (accelerationParallelMultiplied + accelerationPerpendicular)
		else
			accelerationVector = engineAccelerationVectorWorldSpace
		end

		-- If acceleration would increase speed while being over max speed, cap it to previous speed or max speed, whichever is higher. Preserves direction
		local attemptedDelta = accelerationVector * dt
		local attemptedNewVelocity = ship.velocity + attemptedDelta
		local finalDelta, finalNewVelocity
		if #attemptedNewVelocity > ship.maxSpeed and #attemptedNewVelocity > #ship.velocity then
			finalNewVelocity = setVectorLength(
				attemptedNewVelocity,
				math.max(ship.maxSpeed, #ship.velocity) * consts.speedRegulationMultiplier -- Speed regulation multiplier is there to stop precision from letting you go faster and faster
			)
			finalDelta = finalNewVelocity - ship.velocity
			-- #finalDelta may be larger than #attemptedDelta
			-- assert(#finalNewVelocity <= #attemptedNewVelocity, "Attempted to prevent speed increase but speed increased anyway") -- Not confident in the precision when small numbers are involved
		else
			finalDelta = attemptedDelta
			finalNewVelocity = attemptedNewVelocity
		end
		local dampedEngineAcceleration = finalDelta / dt -- If you want to draw an acceleration vector, use this
		ship.velocity = finalNewVelocity

		ship.angularVelocity = moveVectorToTarget2(
			ship.angularVelocity,
			ship.targetAngularVelocityMultiplierVector * ship.maxAngularSpeed,
			ship.maxAngularAcceleration,
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
