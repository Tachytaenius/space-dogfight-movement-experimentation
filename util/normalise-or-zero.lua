local vec3 = require("lib.mathsies").vec3

return function(v)
	if #v == 0 then
		return vec3()
	else
		return vec3.normalise(v)
	end
end
