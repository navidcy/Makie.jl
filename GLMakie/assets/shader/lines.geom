{{GLSL_VERSION}}
{{GLSL_EXTENSIONS}}
{{SUPPORTED_EXTENSIONS}}

struct Nothing{ //Nothing type, to encode if some variable doesn't contain any data
    bool _; //empty structs are not allowed
};

{{define_fast_path}}

layout(lines_adjacency) in;
layout(triangle_strip, max_vertices = 4) out;

in vec4 g_color[];
in float g_lastlen[];
in uvec2 g_id[];
in int g_valid_vertex[];
in float g_thickness[];

out vec4 f_color;
out vec3 f_quad_sdf; // smooth edges (along length and width)
out vec2 f_joint_cutoff; // hard edges (joint)
out float f_line_width;
out float f_cumulative_length;
flat out uvec2 f_id;

out vec3 o_view_pos;
out vec3 o_view_normal;

uniform vec2 resolution;

// Constants
#define MITER_LIMIT -0.4
#define AA_THICKNESS 4

vec3 screen_space(vec4 vertex) {
    return vec3((0.5 * vertex.xy + 0.5) * resolution, vertex.z) / vertex.w;
}

////////////////////////////////////////////////////////////////////////////////
/// new version
////////////////////////////////////////////////////////////////////////////////

/*
How it works:
1. geom shader generates a large enough quad:
    - width: max(linewidth) + AA pad
    - length: line segment length + join pad + AA pad
2. fragment shader generates SDF and takes care of AA, clean line joins
    - generate rect sdf matching line segment w/o truncation but with join extension
    - adjust sdf to truncate join without AA
*/

struct LineData {
    vec3 p1, p2, v;
    float segment_length, extrusion_a, extrusion_b;
    vec2 n, miter_v_a, miter_n_a, miter_v_b, miter_n_b;
    float miter_offset_a, miter_offset_b;
    bool is_start, is_end;
};

void emit_vertex(vec3 origin, vec2 center, LineData line, int index, vec2 geom_offset) {
    vec3 position = origin + geom_offset.x * line.v + vec3(geom_offset.y * line.n, 0);

    // sdf prototyping

    // joint hard cutoff
    // if line start/end move hard cutoff out so smooth rect cutoff can act
    vec2 VP1 = position.xy - line.p1.xy;
    vec2 VP2 = position.xy - line.p2.xy;
    f_joint_cutoff = vec2(
        line.is_start ? -10.0 : dot(VP1, -line.miter_v_a),
        line.is_end   ? -10.0 : dot(VP2,  line.miter_v_b)
    );
    // note miter_v_a and miter_v_b are different, so no -width .. + width merge
    // also no max


    // rect
    // vec2 VC = position.xy - center;
    // can't have absolute, will break interpolation
    // f_rect_sdf = vec2(
    //     abs(dot(VC, v)) - 0.5 * segment_length, // - extrusion, apply in frag? do we need 0 edge?
    //     abs(dot(VC, n)) - thickness
    // );
    // f_rect_sdf = vec2(dot(VC, line.v.xy), dot(VC, line.n));

    // joint soft cutoff
    // need miter_offset to be big if no truncation
    // f_joint_smooth = vec2(100.0, 100.0);
    // if (line.miter_offset_a < 0.5) // truncated join condition
    //     f_joint_smooth.x = dot(VP1, line.miter_n_a) - 0.5 * g_thickness[1] * line.miter_offset_a;
    // if (line.miter_offset_b < 0.5) // truncated join condition
    //     f_joint_smooth.y = dot(VP2, line.miter_n_b) - 0.5 * g_thickness[2] * line.miter_offset_b;


    /*
        #######
        width sdf:
            vert/geom: x = dot(vertex_pos - center, line.n)
            frag:      sd = abs(x) - unpadded_linewidth
        length sdf:
            start sdf:
                vert/geom: x = dot(vertex_pos - P1, -line.v)
                frag:      sd = x
            stop sdf:
                vert/goem: x = dot(vertex_pos - P2, line.v);
                frag:      sd = x
            smooth truncated join sdf:
                vert/geom: x = dot(vertex_pos - P1/P2, sign(dot(miter_v, v)) * miter_v) - miter_distance
                frag:      sd = x
            sharp join sdf:
                vert/geom: x = -10.0
                frag:      sd = x
    */

    // SDF in (v dir at P1, v dir at P2, n dir) (default is sharp joint)
    f_quad_sdf = vec3(-1.0, -1.0, dot(position.xy - center, line.n));

    if (line.is_start) // flat line end
        f_quad_sdf.x = dot(VP1, -line.v.xy);
    else if (line.miter_offset_a < 0.5) // truncated joint
        f_quad_sdf.x = dot(VP1, line.miter_n_a) - 0.5 * g_thickness[1] * line.miter_offset_a;

    if (line.is_end) // flat line end
        f_quad_sdf.y = dot(VP2, line.v.xy);
    else if (line.miter_offset_b < 0.5) // truncated joint
        f_quad_sdf.y = dot(VP2, line.miter_n_b) - 0.5 * g_thickness[2] * line.miter_offset_b;


    // f_line_length = 0.5 * line.segment_length;
    f_line_width = 0.5 * g_thickness[index];
    f_color     = g_color[index];
    gl_Position = vec4((2.0 * position.xy / resolution) - 1.0, position.z, 1.0);
    f_id        = g_id[index];
    // f_line_offset = 0.5 * (g_lastlen[1] + g_lastlen[2]); // rect_sdf.x is centered
    f_cumulative_length = g_lastlen[index]; // TODO
    EmitVertex();
}

void emit_quad(LineData line) {
    vec2 center = 0.5 * (line.p1.xy + line.p2.xy);
    float geom_linewidth = 0.5 * max(g_thickness[1], g_thickness[2]) + AA_THICKNESS;
    emit_vertex(line.p1, center, line, 1, vec2(- (line.extrusion_a + AA_THICKNESS), -geom_linewidth));
    emit_vertex(line.p1, center, line, 1, vec2(- (line.extrusion_a + AA_THICKNESS), +geom_linewidth));
    emit_vertex(line.p2, center, line, 2, vec2(+ (line.extrusion_b + AA_THICKNESS), -geom_linewidth));
    emit_vertex(line.p2, center, line, 2, vec2(+ (line.extrusion_b + AA_THICKNESS), +geom_linewidth));

    EndPrimitive();
}

void main(void)
{
    // These need to be set but don't have reasonable values here
    o_view_pos = vec3(0);
    o_view_normal = vec3(0);

    // we generate very thin lines for linewidth 0, so we manually skip them:
    if (g_thickness[1] == 0.0 && g_thickness[2] == 0.0) {
        return;
    }

    // We mark each of the four vertices as valid or not. Vertices can be
    // marked invalid on input (eg, if they contain NaN). We also mark them
    // invalid if they repeat in the index buffer. This allows us to render to
    // the very ends of a polyline without clumsy buffering the position data on the
    // CPU side by repeating the first and last points via the index buffer. It
    // just requires a little care further down to avoid degenerate normals.
    bool isvalid[4] = bool[](
        g_valid_vertex[0] == 1 && g_id[0].y != g_id[1].y,
        g_valid_vertex[1] == 1,
        g_valid_vertex[2] == 1,
        g_valid_vertex[3] == 1 && g_id[2].y != g_id[3].y
    );

    if(!isvalid[1] || !isvalid[2]){
        // If one of the central vertices is invalid or there is a break in the
        // line, we don't emit anything.
        return;
    }

    // Time to generate our quad. For this we need to find out how far a join
    // extends the line. First let's get some vectors we need.

    // Get the four vertices passed to the shader in pixel space.
    // Without FAST_PATH the conversions happen on the CPU
#ifdef FAST_PATH
    vec3 p0 = screen_space(gl_in[0].gl_Position); // start of previous segment
    vec3 p1 = screen_space(gl_in[1].gl_Position); // end of previous segment, start of current segment
    vec3 p2 = screen_space(gl_in[2].gl_Position); // end of current segment, start of next segment
    vec3 p3 = screen_space(gl_in[3].gl_Position); // end of next segment
#else
    vec3 p0 = gl_in[0].gl_Position.xyz; // start of previous segment
    vec3 p1 = gl_in[1].gl_Position.xyz; // end of previous segment, start of current segment
    vec3 p2 = gl_in[2].gl_Position.xyz; // end of current segment, start of next segment
    vec3 p3 = gl_in[3].gl_Position.xyz; // end of next segment
#endif

    // determine the direction of each of the 3 segments (previous, current, next)
    vec3 v1 = p2 - p1;
    float segment_length = length(v1.xy);
    v1 = v1 / segment_length;
    vec3 v0 = v1;
    vec3 v2 = v1;
    if (p1 != p0 && isvalid[0])
        v0 = (p1 - p0) / length(p1.xy - p0.xy);
    if (p3 != p2 && isvalid[3])
        v2 = (p3 - p2) / length(p3.xy - p2.xy);

    // determine the normal of each of the 3 segments (previous, current, next)
    vec2 n0 = vec2(-v0.y, v0.x);
    vec2 n1 = vec2(-v1.y, v1.x);
    vec2 n2 = vec2(-v2.y, v2.x);

    // Compute variables for line joints
    LineData line;
    line.p1 = p1;
    line.p2 = p2;
    line.v = v1;
    line.n = n1;
    line.segment_length = segment_length;
    line.is_start = !isvalid[0];
    line.is_end = !isvalid[3];

    // We create a second (imaginary line for each of the joins which averages the
    // directions of the previous lines. For the corner at P1 this line has
    // normal = miter_n_a = normalize(n0 + n1)
    // direction = miter_v_a = normalize(v0 + v1) = vec2(normal.y, -normal.x)
    line.miter_n_a = normalize(n0 + n1);
    line.miter_n_b = normalize(n1 + n2);
    line.miter_v_a = vec2(line.miter_n_a.y, -line.miter_n_a.x);
    line.miter_v_b = vec2(line.miter_n_b.y, -line.miter_n_b.x);

    // The normal of this new line defines the edge between two line segments
    // with a sharp join:
    //       _______________
    //      |'.              ^
    //    ^ |  '. miter_n_a  | n1
    // v0 | |    '._________
    //      |  n0 |      -->
    //      | <-- |      v1
    //      |     |
    //
    // From the triangle with unit vectors (miter_n_a, v1, n1) and the linewidth
    // g_thickness[1] along n1 direction follows the necessary extrusion for
    // sharp corners:
    //   dot(length_a * miter_n_a, n1) = g_thickness[1]
    //   extrusion = dot(length_a * miter_n_a, v1)
    //             = g_thickness[1] * dot(miter_n_a, v1) / dot(miter_n_a, n1)
    //
    // For truncated corners the extrusion will always be <= that of the sharp
    // corner, so we can just clamp the extrusion at the appropriate maximum
    // value. Truncation happens when the angle between v0 and v1 exceeds some
    // value, e.g. 120°, or half of that between miter_v_a and v1. We choose
    // truncation if
    //   dot(miter_v_a, v1) < 0.5   (120° between segments)
    // or equivalently
    //   dot(miter_n_a, n1) < 0.5
    // giving use the limit:
    float linewidth = 0.5 * max(g_thickness[1], g_thickness[2]);
    line.miter_offset_a = dot(line.miter_n_a, n1);
    line.miter_offset_b = dot(line.miter_n_b, n1);
    line.extrusion_a = linewidth * abs(dot(line.miter_n_a, v1.xy)) / max(0.5, line.miter_offset_a);
    line.extrusion_b = linewidth * abs(dot(line.miter_n_b, v1.xy)) / max(0.5, line.miter_offset_b);

    // For truncated joins we also need to know how far the edge of the joint
    // (between a and b) is from the center point which the line segments share
    // (x).
    //        ----------a.
    //                  | '.
    //                  x  '.
    //        ------.    '--_b
    //             /        /
    //            /        /
    //
    // This distance is given by linewidth * dot(miter_n_a, n1)
    line.miter_offset_a = isvalid[0] ? line.miter_offset_a : 1.0; // else this may create 2 edges
    line.miter_offset_b = isvalid[3] ? line.miter_offset_b : 1.0; // else this may create 2 edges

    // For the distance we also need the miter normals to consistently point
    // outwards (i.e. towards the a-b line). We can enforce this using the line
    // directions
    // line.miter_n_a *= (dot(line.miter_n_a, v1.xy) < 0.0 ? 1.0 : -1.0);
    // line.miter_n_b *= (dot(line.miter_n_b, v1.xy) < 0.0 ? -1.0 : 1.0);

    emit_quad(line);

    return;
}
