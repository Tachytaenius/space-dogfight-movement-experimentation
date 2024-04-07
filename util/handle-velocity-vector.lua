local mathsies = require("lib.mathsies")
local vec3 = mathsies.vec3
local quat = mathsies.quat

local moveVectorToTarget = require("util.move-vector-to-target")
local limitVectorLength = require("util.limit-vector-length")
local setVectorLength = require("util.set-vector-length")
local axisAngleVectorBetweenVectors = require("util.axis-angle-between-vectors")

-- This moves a velocity vector from current to target at a rate over a time step of dt,
-- but there is a lerp between the approach of moving linearly from current to target and just moving in the direction of target (or "origin to target"),
-- and also you can't accelerate beyond your max speed (though you can maintain a speed above max speed (though, changing directions makes you lose that speed due to another feature)),
-- and you also are optionally made to decelerate towards max speed when above it (though the rate (passive rate) can be 0 to disable that feature),
-- and you can also specify a deceleration to apply when moving perpendicular from current velocity when above max speed (to stop you from being able to change movement direction while maintaining excessive speed).
-- This works fine for both linear and angular velocity vectors.
-- Note that "move" is used to mean both moving the vector and the movement the vector represents.

return function(
	current,
	target,
	rate,
	dt,
	lerpFactor,
	maxSpeed,
	overMaxSpeedPassiveDeceleration,
	overMaxSpeedPerpendicularMoveDeceleration
)
	local originalCurrent = vec3.clone(current) -- Used to calculate delta

	-- If within range (considering deceleration over max speed) then jump instead of moving normally.
	local jumped = false
	if vec3.distance(current, target) <= rate * dt then
		current = vec3.clone(target)
		jumped = true
	end
	-- Decelerate if over max speed (whether we jumped or not).
	-- This was placed here after certain ordering didn't work, possibly this could be rearranged and refactored.
	if #current > maxSpeed then
		current = setVectorLength( -- Relies on use of normaliseOrZero
			current,
			math.max(maxSpeed, #current - overMaxSpeedPassiveDeceleration * dt)
		)
	end

	if not jumped then
		-- Avoid normalising zero vector
		if #target == 0 then
			current = moveVectorToTarget(current, target, rate, dt)
		elseif vec3.distance(current, target) == 0 then
			current = vec3.clone(current)
		else
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

			-- Move current in the movement direction but don't go above max speed, or current speed if higher.
			-- You shouldn't be able to go above max speed, but if you have, then you should be able to maintain your current speed but go no higher.
			current = limitVectorLength(
				current + moveDirection * rate * dt,
				math.max(maxSpeed, #current)
			)
		end
	end

	-- Regardless as to how we moved, decelerate with perpendicular movement if over max speed
	if #current > maxSpeed and #originalCurrent > 0 then
		-- Get perpendicular movement since start
		local originalDirection = vec3.normalise(originalCurrent)
		local dot = vec3.dot(current, originalDirection)
		local currentParallel = dot * originalDirection
		local currentPerpendicular = current - currentParallel
		local deceleration = #currentPerpendicular * overMaxSpeedPerpendicularMoveDeceleration
		current = setVectorLength(
			current,
			math.max(maxSpeed, #current - deceleration * dt)
		)
	end

	return current
end
