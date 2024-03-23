varying vec3 vertexNormalWorld;

#ifdef VERTEX

attribute vec3 VertexNormal;

uniform mat4 modelToClip;

vec4 position(mat4 loveTransform, vec4 vertexPosModel) {
	vertexNormalWorld = VertexNormal;
	return modelToClip * vertexPosModel;
}

#endif

#ifdef PIXEL

vec4 effect(vec4 colour, sampler2D image, vec2 textureCoords, vec2 windowCoords) {
	return vec4(vertexNormalWorld * 0.5 + 0.5, 1.0);
}

#endif
