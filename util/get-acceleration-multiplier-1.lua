local sign = require("util.sign")

return function(velocity, acceleration, maxSpeed, accelCurveShaper)
	if acceleration == 0 then
		return 0
	end
	local function getAccelerationMultiplierCore(speed, acceleration)
		-- Speed can't be negative, and acceleration should be negated (whether that's positive or negative) if velocity was too
		if acceleration <= 0 then
			return 1
		end
		return ((maxSpeed - speed) / maxSpeed) ^ (1 / accelCurveShaper)
	end
	if velocity > -maxSpeed and velocity <= 0 then
		return getAccelerationMultiplierCore(-velocity, -acceleration)
	elseif velocity >= 0 and velocity < maxSpeed then
		return getAccelerationMultiplierCore(velocity, acceleration)
	elseif sign(velocity) * sign(acceleration) == 1 then
		-- If you're trying to accelerate in the same direction you're moving and abs(vel) >= maxSpeed then no movement
		return 0
	else
		return 1
	end
end
