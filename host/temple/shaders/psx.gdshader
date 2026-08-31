shader_type spatial;

// The room's surfaces, drawn the way a 1994 console drew them.
//
// Four things made that hardware look the way it did, and three of them are
// here. The fourth - no depth buffer, so polygons sort by their centre and
// swap in front of each other - is a bug people remember fondly and would be
// an actual bug in a room somebody has to read a screen in, so it is left out.
//
//   affine texture mapping   the texture swims and shears on a big polygon,
//                            because the rasteriser interpolated across the
//                            screen and not across the surface
//   vertex snapping          positions land on a coarse grid, so edges twitch
//                            as the camera moves - there was no sub-pixel
//                            precision to land between
//   colour quantisation      fifteen bits out, ordered-dithered, so gradients
//                            break into a cross-hatch rather than into bands
//
// Vertex lighting rather than per-pixel, for the same reason: that machine lit
// corners and interpolated between them.

render_mode vertex_lighting, diffuse_lambert, specular_disabled;

uniform sampler2D albedo : source_color, filter_nearest, repeat_enable;
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec3 tint : source_color = vec3(1.0);

// How coarse the vertex grid is, across the screen. Lower is more of a wobble.
// 160 is about what a 320-wide framebuffer gave.
uniform float snap = 160.0;

// Bits per channel out. 5 is what the console's framebuffer held.
uniform float levels = 31.0;

varying vec2 aff_uv;
varying float aff_w;

void vertex() {
	// MODELVIEW as well as PROJECTION. In Godot 4 the VERTEX handed to this
	// function is still in model space - the transform happens after it returns
	// - so projecting it directly puts every wall somewhere behind the camera
	// and the room renders as an empty black box with a floating monitor in it.
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));

	// Land the vertex on a grid, in normalised device coordinates, then put it
	// back into clip space. Doing it after the divide by w is what makes the
	// wobble depend on distance the way it did: a far-off wall snaps in bigger
	// steps than the desk in front of you.
	vec2 grid = vec2(snap, snap * 0.75);
	clip.xy = round(clip.xy / clip.w * grid) / grid * clip.w;
	POSITION = clip;

	// Affine texture mapping, which is the whole trick of the look.
	//
	// The GPU interpolates a varying perspective-correctly: it carries v/w and
	// 1/w across the triangle and divides at the end. Handing it v*w instead
	// means what arrives is (sum of lambda*v) / (sum of lambda/w), and handing
	// it w as well gives 1 / (sum of lambda/w) - so dividing one by the other
	// leaves plain screen-space interpolation. Which is exactly what a
	// rasteriser with no divider did, and why the textures swim.
	aff_uv = UV * uv_scale * clip.w;
	aff_w = clip.w;
}

// The 4x4 ordered matrix, as arithmetic rather than a lookup table.
float bayer(vec2 p) {
	vec2 c = floor(mod(p, 4.0));
	float i = c.y * 4.0 + c.x;
	// The classic Bayer ordering, written out. A formula for it exists and is
	// unreadable; sixteen numbers are not.
	float m[16] = {0.0, 8.0, 2.0, 10.0,
			12.0, 4.0, 14.0, 6.0,
			3.0, 11.0, 1.0, 9.0,
			15.0, 7.0, 13.0, 5.0};
	return m[int(i)] / 16.0 - 0.5;
}

void fragment() {
	vec2 uv = aff_uv / aff_w;
	vec3 c = texture(albedo, uv).rgb * tint;
	// Quantise with a dither offset of one step, so a colour between two levels
	// comes out as a checker of both instead of picking one.
	float d = bayer(FRAGCOORD.xy);
	c = floor(c * levels + 0.5 + d) / levels;
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
