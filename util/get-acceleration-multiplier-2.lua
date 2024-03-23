local vec3 = require("lib.mathsies").vec3

local normaliseOrZero = require("util.normalise-or-zero")

return function(velocity, acceleration, maxSpeed, accelCurveShaper)
	return 1 - (
		(
			math.max(
				0,
				vec3.dot( -- Since velocity is not normalised this is affected by speed as well as the two vectors' alignment
					velocity,
					normaliseOrZero(acceleration)
				)
			)
		) / maxSpeed
	) ^ (1 / accelCurveShaper)
end
