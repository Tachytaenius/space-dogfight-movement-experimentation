local normaliseOrZero = require("util.normalise-or-zero")

return function(v, l)
	return normaliseOrZero(v) * l
end
