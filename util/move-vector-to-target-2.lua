local mathsies = require("lib.mathsies")
local vec3 = mathsies.vec3
local quat = mathsies.quat

local moveVectorToTarget = require("util.move-vector-to-target")
local limitVectorLength = require("util.limit-vector-length")
local axisAngleVectorBetweenVectors = require("util.axis-angle-between-vectors")

return function(current, target, rate, dt, lerpFactor)
	-- If we could jump this frame, do so
	if vec3.distance(current, target) <= rate * dt then
		return vec3.clone(target)
	end
	-- Avoid normalising zero vector
	if #target == 0 then
		return moveVectorToTarget(current, target, rate, dt)
	end

	lerpFactor = lerpFactor or 0
	if #current > #target then
		lerpFactor = 0
	end

	-- Calculate direction which is between direction from current to target and direction of target itself (lerpFactor being 0 is former, lerpFactor being 1 is latter)
	local currentToTarget = target - current
	local axisBetweenMethods, angleBetweenMethods = axisAngleVectorBetweenVectors(
		vec3.normalise(currentToTarget),
		vec3.normalise(target)
	)
	local moveDirection
	if not axisBetweenMethods then
		-- currentToTarget and target are parallel.
		-- This either means that they are in the same direction, in which case moveDirection can be either,
		-- or it means that they are in opposite diretions, in which case currentToTarget is the reasonable default
		moveDirection = vec3.normalise(currentToTarget)
	else
		local rotationFromCurrentToTargetMethodToMoveDirection = quat.fromAxisAngle(axisBetweenMethods * angleBetweenMethods * lerpFactor)
		moveDirection = vec3.rotate(vec3.normalise(currentToTarget), rotationFromCurrentToTargetMethodToMoveDirection)
	end

	-- Move current in the movement direction but don't go above target speed, or if higher, current speed
	local magnitudeLimit = math.max(#target, #current)
	local movedCurrent = current + moveDirection * rate * dt
	local limitedMovedCurrent = limitVectorLength(movedCurrent, magnitudeLimit)

	return limitedMovedCurrent
end
