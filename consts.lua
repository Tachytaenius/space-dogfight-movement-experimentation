local vec3 = require("lib.mathsies").vec3

local consts = {}

consts.tau = math.pi * 2

consts.vertexFormat = {
	{"VertexPosition", "float", 3},
	{"VertexTexCoord", "float", 2},
	{"VertexNormal", "float", 3}
}

consts.loadObjCoordMultiplier = vec3(1, 1, -1)

consts.forwardVector = vec3(0, 0, 1)
consts.upVector = vec3(0, 1, 0)
consts.rightVector = vec3(1, 0, 0)

consts.airDensity = 0.9
consts.speedRegulationHarshness = 10e-10
consts.speedRegulationMultiplier = 1 - consts.speedRegulationHarshness

return consts
